defmodule ImgdWeb.WorkflowLive.Runner do
  @moduledoc """
  LiveView for running and observing workflow executions in real-time.

  Features:
  - Visual DAG representation with live node status updates
  - Real-time trace log streaming
  - Node configuration modal with expression support
  - Pin management for iterative development
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Executions
  alias Imgd.Executions.{Execution, NodeExecution, Context, PubSub}
  alias Imgd.Workflows.DagLayout
  alias ImgdWeb.WorkflowLive.NodeConfigModal
  import ImgdWeb.WorkflowLive.RunnerComponents

  @trace_log_limit 500

  @impl true
  def mount(%{"id" => workflow_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow(scope, workflow_id, preload: [:published_version]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow not found")
         |> redirect(to: ~p"/workflows")}

      workflow ->
        {:ok, versions} = Workflows.list_workflow_versions(scope, workflow)
        versions_map = Map.new(versions, &{&1.id, &1})

        demo_inputs = workflow_demo_inputs(workflow)
        initial_demo = List.first(demo_inputs)
        initial_payload = if(initial_demo, do: initial_demo.data, else: %{})
        run_form = build_run_form(initial_payload, version_id: "draft")

        socket =
          socket
          |> assign(:page_title, "Run: #{workflow.name}")
          |> assign(:workflow, workflow)
          |> assign(:versions, versions)
          |> assign(:versions_map, versions_map)
          |> assign(:selected_version_id, "draft")
          |> assign_source_graph(workflow)
          |> assign(:execution, nil)
          |> assign(:execution_context, nil)
          |> assign(:node_states, %{})
          |> assign(:selected_node_id, nil)
          |> assign(:running?, false)
          |> assign(:can_run?, length(workflow.nodes || []) > 0)
          |> assign(:trace_log_count, 0)
          |> assign(:demo_inputs, demo_inputs)
          |> assign(:selected_demo, initial_demo)
          |> assign(:run_form, run_form)
          |> assign(:run_form_error, nil)
          # Modal state
          |> assign(:show_config_modal, false)
          |> assign(:config_modal_node, nil)
          # Context menu state
          |> assign(:show_context_menu, false)
          |> assign(:context_menu_node_id, nil)
          |> assign(:context_menu_position, %{x: 0, y: 0})
          |> assign(:pins_with_status, Workflows.get_pinned_outputs_with_status(workflow))
          |> stream(:trace_log, [], dom_id: &"trace-#{&1.id}")

        {:ok, socket}
    end
  end

  defp assign_source_graph(socket, source) do
    nodes = source.nodes || []
    connections = source.connections || []

    {layout, layout_meta} =
      DagLayout.compute_with_metadata(nodes, connections)

    edges = DagLayout.compute_edges(connections, layout)
    node_map = Map.new(nodes, &{&1.id, &1})

    socket
    |> assign(:graph_nodes, nodes)
    |> assign(:dag_layout, layout)
    |> assign(:dag_edges, edges)
    |> assign(:dag_meta, layout_meta)
    |> assign(:node_map, node_map)
  end

  @impl true
  def handle_params(%{"execution_id" => execution_id}, _uri, socket) do
    scope = socket.assigns.current_scope

    case Executions.get_execution(scope, execution_id,
           preload: [:node_executions, :workflow_version]
         ) do
      nil ->
        {:noreply, put_flash(socket, :error, "Execution not found")}

      execution ->
        PubSub.subscribe_execution(execution.id)
        node_states = build_node_states_from_execution(execution)

        # Build execution context for expression preview
        exec_context = build_execution_context(execution, node_states)

        # Source for graph rendering
        source = execution.workflow_version || socket.assigns.workflow

        version_id =
          if execution.workflow_version, do: execution.workflow_version.id, else: "draft"

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:execution_context, exec_context)
          |> assign(:node_states, node_states)
          |> assign(:running?, Execution.active?(execution))
          |> assign(:selected_version_id, version_id)
          |> assign(
            :run_form,
            build_run_form(get_trigger_data_from_execution(execution), version_id: version_id)
          )
          |> assign_source_graph(source)
          |> maybe_stream_existing_logs(execution)

        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp get_trigger_data_from_execution(execution) do
    data = Execution.trigger_data(execution)

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  # ============================================================================
  # Build Execution Context for Expression Preview
  # ============================================================================

  defp build_execution_context(nil, _), do: nil

  defp build_execution_context(%Execution{} = execution, node_states) do
    # Build node outputs from node_states
    node_outputs =
      node_states
      |> Enum.filter(fn {_, state} -> state[:output_data] != nil end)
      |> Enum.map(fn {node_id, state} -> {node_id, state[:output_data]} end)
      |> Map.new()

    # Create context with accumulated outputs
    Context.new(execution)
    |> Map.put(:node_outputs, node_outputs)
  end

  # ============================================================================
  # Node Config Modal Events
  # ============================================================================

  @impl true
  def handle_event("open_node_config", %{"node-id" => node_id}, socket) do
    node = Map.get(socket.assigns.node_map, node_id)

    if node do
      socket =
        socket
        |> assign(:show_config_modal, true)
        |> assign(:config_modal_node, node)
        |> assign(:show_context_menu, false)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_event("close_config_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_config_modal, false)
     |> assign(:config_modal_node, nil)}
  end

  @impl true
  def handle_event("run_workflow", params, socket) do
    handle_full_workflow_run(params, socket)
  end

  @impl true
  def handle_event("select_demo_input", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.demo_inputs, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      demo ->
        {:noreply,
         socket
         |> assign(:selected_demo, demo)
         |> assign(:run_form, build_run_form(demo.data))
         |> assign(:run_form_error, nil)}
    end
  end

  @impl true
  def handle_event("update_payload", %{"run" => params}, socket) do
    data = Map.get(params, "data", "")
    version_id = Map.get(params, "version_id", "draft")

    socket =
      if version_id != socket.assigns.selected_version_id do
        source =
          if version_id == "draft" do
            socket.assigns.workflow
          else
            Map.get(socket.assigns.versions_map, version_id)
          end

        socket
        |> assign(:selected_version_id, version_id)
        |> assign_source_graph(source)
      else
        socket
      end

    socket =
      socket
      |> assign(:run_form, build_run_form(data, version_id: version_id))
      |> maybe_reset_selected_demo(data)
      |> assign(:run_form_error, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_to_node", %{"node-id" => node_id}, socket) do
    handle_execute_to_node_impl(socket, node_id)
  end

  # ============================================================================
  # Node Selection & Context Menu
  # ============================================================================

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    # Double-click opens modal, single click selects
    selected = if socket.assigns.selected_node_id == node_id, do: nil, else: node_id
    {:noreply, assign(socket, :selected_node_id, selected)}
  end

  @impl true
  def handle_event("open_context_menu", %{"node-id" => node_id, "x" => x, "y" => y}, socket) do
    socket =
      socket
      |> assign(:show_context_menu, true)
      |> assign(:context_menu_node_id, node_id)
      |> assign(:context_menu_position, %{x: x, y: y})

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_context_menu", _params, socket) do
    socket =
      socket
      |> assign(:show_context_menu, false)
      |> assign(:context_menu_node_id, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_node_id, nil)}
  end

  # ============================================================================
  # Pin Management Events
  # ============================================================================

  @impl true
  def handle_event("clear_pin", %{"node-id" => node_id}, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow

    case Workflows.unpin_node_output(scope, workflow, node_id) do
      {:ok, updated_workflow} ->
        socket =
          socket
          |> assign(:workflow, updated_workflow)
          |> assign(:pins_with_status, Workflows.get_pinned_outputs_with_status(updated_workflow))
          |> assign(:show_context_menu, false)
          |> put_flash(:info, "Pin removed")
          |> append_trace_log(:info, "Removed pin", %{node_id: node_id})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove pin: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_event("clear_all_pins", _params, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow

    case Workflows.clear_all_pins(scope, workflow) do
      {:ok, updated_workflow} ->
        socket =
          socket
          |> assign(:workflow, updated_workflow)
          |> assign(:pins_with_status, %{})
          |> put_flash(:info, "All pins cleared")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear pins: #{format_error(reason)}")}
    end
  end

  # ============================================================================
  # Execution Mode Handlers
  # ============================================================================

  defp handle_full_workflow_run(params, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    run_params = Map.get(params, "run", %{})
    input_string = Map.get(run_params, "data", "")
    version_id = Map.get(run_params, "version_id", "draft")

    if socket.assigns.can_run? do
      with {:ok, parsed} <-
             parse_input_payload(input_string, socket.assigns.demo_inputs),
           {:ok, %{execution: execution}} <-
             Executions.start_and_enqueue_execution(scope, workflow, %{
               workflow_version_id: version_id,
               trigger: %{type: :manual, data: parsed.trigger_data},
               metadata: build_manual_metadata(parsed.demo_label)
             }) do
        PubSub.subscribe_execution(execution.id)
        run_form = build_run_form(input_string, version_id: version_id)

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:running?, true)
          |> assign(:node_states, %{})
          |> assign(:execution_context, nil)
          |> assign(:trace_log_count, 0)
          |> assign(:selected_demo, parsed.demo)
          |> assign(:run_form, run_form)
          |> assign(:run_form_error, nil)
          |> stream(:trace_log, [], reset: true)
          |> append_trace_log(:info, "Execution started", %{
            execution_id: short_id(execution.id),
            version: version_id
          })
          |> push_patch(to: ~p"/workflows/#{workflow.id}/run?execution_id=#{execution.id}")

        {:noreply, socket}
      else
        {:error, :invalid_payload, message} ->
          {:noreply,
           socket
           |> assign(
             :run_form,
             build_run_form(input_string, version_id: version_id, errors: [data: {message, []}])
           )
           |> assign(:run_form_error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Workflow must have nodes before running")}
    end
  end

  defp handle_execute_to_node_impl(socket, node_id) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    trigger_data = get_trigger_data_from_form(socket)
    version_id = socket.assigns.selected_version_id

    case Executions.execute_node(scope, workflow, node_id,
           workflow_version_id: version_id,
           trigger_data: trigger_data,
           async: true,
           subscribe_fun: &PubSub.subscribe_execution/1
         ) do
      {:ok, execution} ->
        PubSub.subscribe_execution(execution.id)

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:running?, true)
          |> assign(:node_states, build_initial_pin_states(workflow))
          |> assign(:execution_context, nil)
          |> assign(:trace_log_count, 0)
          |> stream(:trace_log, [], reset: true)
          |> append_trace_log(:info, "Partial execution started", %{
            partial: true,
            target: node_id,
            version: version_id
          })
          |> push_patch(to: ~p"/workflows/#{workflow.id}/run?execution_id=#{execution.id}")
          |> assign(:show_context_menu, false)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Execution failed: #{format_error(reason)}")}
    end
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  # Handle messages from NodeConfigModal
  @impl true
  def handle_info(:close_node_config_modal, socket) do
    {:noreply,
     socket
     |> assign(:show_config_modal, false)
     |> assign(:config_modal_node, nil)}
  end

  @impl true
  def handle_info({:node_config_saved, node_id, new_config}, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow

    # Update the node's config in the workflow
    updated_nodes =
      Enum.map(workflow.nodes || [], fn node ->
        # Convert struct to map so Ecto can cast it correctly in the changeset
        node_params = Map.from_struct(node)

        if node.id == node_id do
          %{node_params | config: new_config}
        else
          node_params
        end
      end)

    case Workflows.update_workflow(scope, workflow, %{nodes: updated_nodes}) do
      {:ok, updated_workflow} ->
        node_map = Map.new(updated_workflow.nodes || [], &{&1.id, &1})

        socket =
          socket
          |> assign(:workflow, updated_workflow)
          |> assign(:node_map, node_map)
          |> assign(:show_config_modal, false)
          |> assign(:config_modal_node, nil)
          |> put_flash(:info, "Node configuration saved")
          |> append_trace_log(:info, "Node config updated", %{node_id: short_id(node_id)})

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration")}
    end
  end

  @impl true
  def handle_info({:pin_node_output, node_id, output_data, label}, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    execution_id = socket.assigns.execution && socket.assigns.execution.id

    case Workflows.pin_node_output(scope, workflow, node_id, output_data,
           execution_id: execution_id,
           label: if(label == "", do: nil, else: label)
         ) do
      {:ok, updated_workflow} ->
        socket =
          socket
          |> assign(:workflow, updated_workflow)
          |> assign(:pins_with_status, Workflows.get_pinned_outputs_with_status(updated_workflow))
          |> put_flash(:info, "Output pinned successfully")
          |> append_trace_log(:info, "Pinned node output", %{node_id: node_id})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pin: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_info({:execution_started, execution}, socket) do
    socket =
      socket
      |> assign(:execution, execution)
      |> assign(:running?, true)
      |> append_trace_log(:info, "Execution running", %{status: execution.status})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execution_updated, execution}, socket) do
    {:noreply, assign(socket, :execution, execution)}
  end

  @impl true
  def handle_info({:execution_completed, execution}, socket) do
    # Rebuild context now that execution is complete
    node_states = socket.assigns.node_states
    exec_context = build_execution_context(execution, node_states)

    socket =
      socket
      |> assign(:execution, execution)
      |> assign(:execution_context, exec_context)
      |> assign(:running?, false)
      |> append_trace_log(:success, "Execution completed", %{
        duration_us: Execution.duration_us(execution),
        status: execution.status
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execution_failed, execution, error}, socket) do
    socket =
      socket
      |> assign(:execution, execution)
      |> assign(:running?, false)
      |> append_trace_log(:error, "Execution failed", format_error_for_log(error))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_started, payload}, socket) do
    node_id = payload.node_id
    node_name = get_node_name(socket.assigns.node_map, node_id)

    node_states =
      Map.put(socket.assigns.node_states, node_id, %{
        status: :running,
        started_at: payload.started_at,
        queued_at: payload.queued_at,
        input_data: payload.input_data,
        output_data: nil,
        error: nil,
        duration_us: nil
      })

    socket =
      socket
      |> assign(:node_states, node_states)
      |> append_trace_log(:info, "Node started: #{node_name}", %{
        node_type: payload.node_type_id,
        node_id: short_id(node_id)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_completed, payload}, socket) do
    node_id = payload.node_id
    node_name = get_node_name(socket.assigns.node_map, node_id)
    existing = Map.get(socket.assigns.node_states, node_id, %{})
    duration_us = payload.duration_us

    node_states =
      Map.put(socket.assigns.node_states, node_id, %{
        status: :completed,
        started_at: existing[:started_at] || payload.started_at,
        completed_at: payload.completed_at,
        duration_us: duration_us,
        input_data: existing[:input_data] || payload.input_data,
        output_data: payload.output_data,
        error: nil
      })

    # Update execution context with new output
    exec_context = build_execution_context(socket.assigns.execution, node_states)

    socket =
      socket
      |> assign(:node_states, node_states)
      |> assign(:execution_context, exec_context)
      |> append_trace_log(:success, "Node completed: #{node_name}", %{
        duration_us: duration_us,
        node_id: short_id(node_id)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_failed, payload}, socket) do
    node_id = payload.node_id
    node_name = get_node_name(socket.assigns.node_map, node_id)
    existing = Map.get(socket.assigns.node_states, node_id, %{})
    duration_us = payload.duration_us

    node_states =
      Map.put(socket.assigns.node_states, node_id, %{
        status: :failed,
        started_at: existing[:started_at] || payload.started_at,
        completed_at: payload.completed_at,
        input_data: existing[:input_data] || payload.input_data,
        output_data: nil,
        error: payload.error,
        duration_us: duration_us
      })

    socket =
      socket
      |> assign(:node_states, node_states)
      |> append_trace_log(
        :error,
        "Node failed: #{node_name}",
        format_error_for_log(payload.error)
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_node_name(node_map, node_id) do
    case Map.get(node_map, node_id) do
      nil -> node_id
      node -> node.name
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "-"

  defp format_error_for_log(nil), do: %{}

  defp format_error_for_log(error) when is_map(error) do
    error
    |> Map.take(["type", "message", "reason", :type, :message, :reason])
    |> Map.new(fn {k, v} -> {to_string(k), truncate_value(v)} end)
  end

  defp format_error_for_log(error), do: %{reason: truncate_value(inspect(error))}

  defp truncate_value(v) when is_binary(v) and byte_size(v) > 100,
    do: String.slice(v, 0, 100) <> "..."

  defp truncate_value(v), do: v

  defp get_trigger_data_from_form(socket) do
    case socket.assigns.run_form do
      %Phoenix.HTML.Form{source: %{"data" => data}} when is_binary(data) ->
        case Jason.decode(data) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp build_initial_pin_states(workflow) do
    (workflow.pinned_outputs || %{})
    |> Enum.map(fn {node_id, pin} ->
      {node_id,
       %{
         status: :skipped,
         output_data: Map.get(pin, "data") || Map.get(pin, :data),
         pinned: true
       }}
    end)
    |> Map.new()
  end

  defp format_error({:node_not_found, id}), do: "Node not found: #{id}"
  defp format_error({:node_not_pinned, id}), do: "Node not pinned: #{id}"
  defp format_error({:nodes_not_found, ids}), do: "Nodes not found: #{Enum.join(ids, ", ")}"
  defp format_error(:no_executable_version), do: "No executable version available"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp parse_input_payload(input_string, demo_inputs) do
    trimmed = String.trim(input_string || "")

    decoded =
      case trimmed do
        "" -> {:ok, %{}}
        _ -> Jason.decode(trimmed)
      end

    case decoded do
      {:ok, value} ->
        trigger_data =
          case value do
            %{} = map -> map
            _other -> %{}
          end

        demo = match_demo_input(value, demo_inputs)

        {:ok,
         %{
           trigger_data: trigger_data,
           decoded: value,
           demo: demo,
           demo_label: demo && demo.label
         }}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, :invalid_payload, "Invalid JSON: #{Exception.message(error)}"}

      _ ->
        {:error, :invalid_payload, "Unable to parse trigger input"}
    end
  end

  defp build_manual_metadata(nil), do: %{extras: %{"runner" => "manual_live"}}

  defp build_manual_metadata(label),
    do: %{extras: %{"runner" => "manual_live", "demo_input" => label}}

  defp build_run_form(payload, opts \\ [])

  defp build_run_form(payload, opts) when is_binary(payload) do
    version_id = Keyword.get(opts, :version_id, "draft")
    to_form(%{"data" => payload, "version_id" => version_id}, Keyword.merge([as: :run], opts))
  end

  defp build_run_form(payload, opts), do: payload |> encode_payload() |> build_run_form(opts)

  defp workflow_demo_inputs(workflow) do
    settings = workflow.settings || %{}

    from_settings =
      settings
      |> fetch_setting(:demo_inputs)
      |> normalize_demo_inputs()

    generated = generate_demo_inputs(workflow)

    inputs =
      (from_settings ++ generated)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    if inputs == [], do: [default_empty_demo()], else: inputs
  end

  defp default_empty_demo do
    normalize_demo_input(%{
      label: "Empty payload",
      description: "Use when the workflow does not require input data",
      data: %{}
    })
  end

  defp normalize_demo_inputs(list) when is_list(list) do
    list |> Enum.map(&normalize_demo_input/1) |> Enum.filter(& &1)
  end

  defp normalize_demo_inputs(map) when is_map(map), do: [normalize_demo_input(map)]
  defp normalize_demo_inputs(_), do: []

  defp normalize_demo_input(nil), do: nil

  defp normalize_demo_input(map) when is_map(map) do
    label = Map.get(map, :label) || Map.get(map, "label") || "Preset"
    data = (Map.get(map, :data) || Map.get(map, "data") || %{}) |> normalize_demo_value()
    description = Map.get(map, :description) || Map.get(map, "description")

    %{id: demo_id(label, data), label: label, description: description, data: data}
  end

  defp demo_id(label, data) do
    slug = label |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    base = if slug == "", do: "demo", else: slug
    "#{base}-#{:erlang.phash2(data)}"
  end

  defp generate_demo_inputs(workflow) do
    nodes = workflow.nodes || []
    type_ids = Enum.map(nodes, & &1.type_id)

    []
    |> maybe_add_math_demo(type_ids)
    |> maybe_add_template_demo(type_ids)
    |> maybe_add_webhook_demo(workflow)
    |> Enum.reverse()
  end

  defp maybe_add_math_demo(acc, type_ids) do
    if Enum.any?(type_ids, &(&1 == "math")) do
      [
        normalize_demo_input(%{
          label: "Sample number input",
          description: "Demonstrates scalar inputs for math workflows",
          data: 21
        })
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_add_template_demo(acc, type_ids) do
    if Enum.any?(type_ids, &(&1 == "format")) do
      [
        normalize_demo_input(%{
          label: "Profile payload",
          description: "Ideal for format/transform demos",
          data: %{
            "name" => "Ada Lovelace",
            "email" => "ada@example.com",
            "company" => %{"name" => "Analytical Engines"}
          }
        })
        | acc
      ]
    else
      acc
    end
  end

  defp maybe_add_webhook_demo(acc, workflow) do
    if has_trigger_type?(workflow, :webhook) do
      [
        normalize_demo_input(%{
          label: "Webhook event",
          description: "Mimics a webhook payload",
          data: %{
            "event" => "user.created",
            "timestamp" =>
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "data" => %{"id" => "evt_123", "email" => "user@example.com"}
          }
        })
        | acc
      ]
    else
      acc
    end
  end

  defp has_trigger_type?(workflow, type) do
    Enum.any?(workflow.triggers || [], fn trigger ->
      trigger.type == type || Map.get(trigger, :type) == type ||
        Map.get(trigger, "type") == to_string(type)
    end)
  end

  defp match_demo_input(value, demo_inputs) do
    normalized_value = normalize_demo_value(value)
    Enum.find(demo_inputs, fn demo -> demo.data == normalized_value end)
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(payload, pretty: true, limit: :infinity)
    end
  end

  defp fetch_setting(settings, key) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end

  defp maybe_reset_selected_demo(socket, data_string) do
    case socket.assigns.selected_demo do
      nil ->
        socket

      demo ->
        encoded_demo = encode_payload(demo.data)

        if String.trim(encoded_demo) == String.trim(data_string) do
          socket
        else
          assign(socket, :selected_demo, nil)
        end
    end
  end

  defp normalize_demo_value(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {normalize_demo_key(k), normalize_demo_value(v)} end)
    |> Map.new()
  end

  defp normalize_demo_value(list) when is_list(list), do: Enum.map(list, &normalize_demo_value/1)
  defp normalize_demo_value(other), do: other

  defp normalize_demo_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_demo_key(key), do: to_string(key)

  defp build_node_states_from_execution(%Execution{} = execution) do
    node_executions = execution.node_executions || []

    Map.new(node_executions, fn ne ->
      {ne.node_id,
       %{
         status: ne.status,
         started_at: ne.started_at,
         completed_at: ne.completed_at,
         duration_us: NodeExecution.duration_us(ne),
         input_data: ne.input_data,
         output_data: ne.output_data,
         error: ne.error
       }}
    end)
  end

  defp maybe_stream_existing_logs(socket, %Execution{} = execution) do
    logs = build_logs_from_execution(execution)

    socket
    |> assign(:trace_log_count, length(logs))
    |> stream(:trace_log, logs, reset: true)
  end

  defp build_logs_from_execution(%Execution{} = execution) do
    base_logs = [
      %{
        id: "exec-start-#{execution.id}",
        level: :info,
        message: "Execution started",
        timestamp: execution.started_at || execution.inserted_at,
        data: %{status: execution.status}
      }
    ]

    node_logs =
      (execution.node_executions || [])
      |> Enum.flat_map(fn ne ->
        started =
          if ne.started_at do
            [
              %{
                id: "node-start-#{ne.id}",
                level: :info,
                message: "Node started: #{ne.node_id}",
                timestamp: ne.started_at,
                data: %{node_type: ne.node_type_id}
              }
            ]
          else
            []
          end

        completed =
          case ne.status do
            :completed ->
              [
                %{
                  id: "node-complete-#{ne.id}",
                  level: :success,
                  message: "Node completed: #{ne.node_id}",
                  timestamp: ne.completed_at,
                  data: %{duration_us: NodeExecution.duration_us(ne)}
                }
              ]

            :failed ->
              [
                %{
                  id: "node-fail-#{ne.id}",
                  level: :error,
                  message: "Node failed: #{ne.node_id}",
                  timestamp: ne.completed_at,
                  data: ne.error
                }
              ]

            _ ->
              []
          end

        started ++ completed
      end)

    end_log =
      if Execution.terminal?(execution) do
        level = if execution.status == :completed, do: :success, else: :error

        [
          %{
            id: "exec-end-#{execution.id}",
            level: level,
            message: "Execution #{execution.status}",
            timestamp: execution.completed_at,
            data: %{duration_us: Execution.duration_us(execution)}
          }
        ]
      else
        []
      end

    (base_logs ++ node_logs ++ end_log)
    |> Enum.sort_by(& &1.timestamp, DateTime)
  end

  defp append_trace_log(socket, level, message, data) do
    entry = %{
      id: "log-#{System.unique_integer([:positive])}",
      level: level,
      message: message,
      timestamp: DateTime.utc_now(),
      data: data
    }

    new_count =
      socket.assigns
      |> Map.get(:trace_log_count, 0)
      |> Kernel.+(1)
      |> min(@trace_log_limit)

    socket
    |> assign(:trace_log_count, new_count)
    |> stream_insert(:trace_log, entry, at: -1, limit: @trace_log_limit)
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-4">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/workflows/#{@workflow.id}"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="size-4" />
              <span>Back</span>
            </.link>
          </div>
          <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
            <div class="space-y-1">
              <h1 class="text-2xl font-semibold tracking-tight text-base-content">
                {@workflow.name}
              </h1>
              <p class="text-sm text-muted">Run and observe workflow execution</p>
            </div>
            <div class="flex items-center gap-3">
              <.execution_status_badge execution={@execution} running?={@running?} />
              <button
                type="submit"
                form="run-config-form"
                disabled={@running? or not @can_run?}
                class={[
                  "btn btn-primary gap-2",
                  (@running? or not @can_run?) && "btn-disabled"
                ]}
              >
                <.icon
                  name={if @running?, do: "hero-arrow-path", else: "hero-play"}
                  class={"size-4#{if @running?, do: " animate-spin", else: ""}"}
                />
                <span>{if @running?, do: "Running...", else: "Run Workflow"}</span>
              </button>
            </div>
          </div>
        </div>
      </:page_header>

      <.run_panel
        run_form={@run_form}
        demo_inputs={@demo_inputs}
        selected_demo={@selected_demo}
        running?={@running?}
        can_run?={@can_run?}
        run_form_error={@run_form_error}
        versions={@versions}
        selected_version_id={@selected_version_id}
      />

      <div class="grid grid-cols-1 xl:grid-cols-3 gap-6">
        <%!-- DAG Visualization --%>
        <div class="xl:col-span-2">
          <.dag_panel
            nodes={@graph_nodes}
            layout={@dag_layout}
            edges={@dag_edges}
            meta={@dag_meta}
            node_map={@node_map}
            node_states={@node_states}
            selected_node_id={@selected_node_id}
            pins_with_status={@pins_with_status}
          />
        </div>

        <%!-- Right Panel --%>
        <div class="space-y-6">
          <.pins_summary_panel
            workflow={@workflow}
            pins_with_status={@pins_with_status}
          />
          <.node_details_panel
            node_map={@node_map}
            node_states={@node_states}
            selected_node_id={@selected_node_id}
          />

          <.trace_log_panel
            trace_log={@streams.trace_log}
            trace_log_count={@trace_log_count}
          />
        </div>
      </div>

      <%!-- Execution Metadata --%>
      <.execution_metadata_panel :if={@execution} execution={@execution} />

      <%!-- Node Config Modal --%>
      <%= if @show_config_modal and @config_modal_node do %>
        <.live_component
          module={NodeConfigModal}
          id={"node-config-#{@config_modal_node.id}"}
          node={@config_modal_node}
          execution_context={@execution_context}
          node_output={get_in(@node_states, [@config_modal_node.id, :output_data])}
          pinned_data={Map.get(@pins_with_status, @config_modal_node.id)}
        />
      <% end %>

      <%!-- Context Menu --%>
      <%= if @show_context_menu and @context_menu_node_id do %>
        <% node = Map.get(@node_map, @context_menu_node_id) %>
        <% pin_status = Map.get(@pins_with_status || %{}, @context_menu_node_id) %>
        <.node_context_menu
          node_id={@context_menu_node_id}
          node_name={(node && node.name) || @context_menu_node_id}
          pinned={Map.has_key?(@workflow.pinned_outputs || %{}, @context_menu_node_id)}
          pin_stale={(pin_status && pin_status["stale"]) || false}
          has_output={get_in(@node_states, [@context_menu_node_id, :output_data]) != nil}
          position={@context_menu_position}
        />
      <% end %>
    </Layouts.app>
    """
  end
end
