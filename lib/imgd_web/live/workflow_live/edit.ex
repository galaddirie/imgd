defmodule ImgdWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for Editing and running workflow executions in real-time.

  Features:
  - Visual DAG representation with live node status updates
  - Real-time trace log streaming
  - Node configuration modal with expression support
  - Pin management for iterative development
  """
  use ImgdWeb, :live_view

  alias Imgd.Collaboration.EditorState
  alias Imgd.Collaboration.EditSession.{Operations, Presence, Server, Supervisor}
  alias Imgd.Executions
  alias Imgd.Executions.{Execution, NodeExecution, PubSub}
  alias Imgd.Runtime.Execution.Supervisor, as: ExecutionSupervisor
  alias Imgd.Workflows
  alias Imgd.Workflows.DagLayout
  alias ImgdWeb.WorkflowLive.Components.NodeConfigModal
  import ImgdWeb.WorkflowLive.RunnerComponents

  @trace_log_limit 500
  @draft_operation_types [
    :add_node,
    :remove_node,
    :update_node_config,
    :update_node_position,
    :update_node_metadata,
    :add_connection,
    :remove_connection
  ]

  @impl true
  def mount(%{"id" => workflow_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow_with_draft(workflow_id, scope) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Workflow not found")
         |> redirect(to: ~p"/workflows")}

      {:ok, workflow} ->
        versions = Workflows.list_workflow_versions(workflow, scope)
        versions_map = Map.new(versions, &{&1.id, &1})

        demo_inputs = workflow_demo_inputs(workflow)
        initial_demo = List.first(demo_inputs)
        initial_payload = if(initial_demo, do: initial_demo.data, else: %{})
        run_form = build_run_form(initial_payload, version_id: "draft")

        with {:ok, edit_session_pid} <- Supervisor.ensure_session(workflow.id),
             {:ok, sync_state} <- Server.get_sync_state(workflow.id) do
          {draft, edit_seq} = sync_state_to_draft(sync_state, workflow)

          editor_state =
            case Server.get_editor_state(workflow.id) do
              {:ok, state} -> state
              _ -> %EditorState{workflow_id: workflow.id}
            end

          node_map = Map.new((draft && draft.nodes) || [], &{&1.id, &1})
          pin_labels = %{}
          pins_with_status = build_pins_with_status(editor_state, node_map, pin_labels)

          socket =
            socket
            |> assign(:page_title, "Run: #{workflow.name}")
            |> assign(:workflow, workflow)
            |> assign(:draft, draft)
            |> assign(:edit_session_pid, edit_session_pid)
            |> assign(:edit_session_seq, edit_seq)
            |> assign(:client_seq, 0)
            |> assign(:editor_state, editor_state)
            |> assign(:presence_tracked?, false)
            |> assign(:locked_node_id, nil)
            |> assign(:pin_labels, pin_labels)
            |> assign(:versions, versions)
            |> assign(:versions_map, versions_map)
            |> assign(:selected_version_id, "draft")
            |> assign_source_graph(draft)
            |> assign(:execution, nil)
            |> assign(:node_states, build_initial_pin_states(workflow, pins_with_status))
            |> assign(:selected_node_id, nil)
            |> assign(:running?, false)
            |> assign(:can_run?, length((draft && draft.nodes) || []) > 0)
            |> assign(:trace_log_count, 0)
            |> assign(:subscribed_execution_id, nil)
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
            |> assign(:pins_with_status, pins_with_status)
            |> maybe_subscribe_to_edit_session(scope, workflow.id)
            |> stream(:trace_log, [], dom_id: &"trace-#{&1.id}")

          {:ok, socket}
        else
          _ ->
            {:ok,
             socket
             |> put_flash(:error, "Unable to start collaborative session")
             |> redirect(to: ~p"/workflows")}
        end
    end
  end

  defp assign_source_graph(socket, source) do
    # Only Workflow has a draft; Versions and Snapshots are themselves the source.
    {nodes, connections} =
      case source do
        %Imgd.Workflows.Workflow{} = workflow ->
          workflow = Imgd.Repo.preload(workflow, :draft)
          draft = workflow.draft
          {(draft && draft.nodes) || [], (draft && draft.connections) || []}

        %{nodes: nodes, connections: connections} ->
          {nodes || [], connections || []}

        _ ->
          {[], []}
      end

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

    case Executions.get_execution_with_nodes(execution_id, scope) do
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Execution not found")}

      {:ok, execution} ->
        version_id = execution_version_id(execution)

        source =
          if version_id == "draft" do
            socket.assigns.draft || socket.assigns.workflow
          else
            Map.get(socket.assigns.versions_map, version_id) ||
              socket.assigns.draft ||
              socket.assigns.workflow
          end

        socket =
          socket
          |> maybe_subscribe_to_execution(execution.id)
          |> assign(:execution, execution)
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
  # Node Config Modal Events
  # ============================================================================

  @impl true
  def handle_event("open_node_config", %{"node-id" => node_id}, socket) do
    node = Map.get(socket.assigns.node_map, node_id)

    if node do
      socket = release_node_lock(socket)

      case acquire_node_lock(socket, node_id) do
        {:ok, socket} ->
          socket =
            socket
            |> assign(:show_config_modal, true)
            |> assign(:config_modal_node, node)
            |> assign(:show_context_menu, false)
            |> maybe_update_presence_focus(node_id)

          {:noreply, socket}

        {:error, {:locked_by, _user_id}} ->
          {:noreply, put_flash(socket, :error, "Node is currently being edited")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Unable to lock node: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_event("close_config_modal", _, socket) do
    {:noreply,
     socket
     |> release_node_lock()
     |> assign(:show_config_modal, false)
     |> assign(:config_modal_node, nil)
     |> maybe_update_presence_focus(nil)}
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
         |> assign(
           :run_form,
           build_run_form(demo.data, version_id: socket.assigns.selected_version_id)
         )
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
            socket.assigns.draft || socket.assigns.workflow
          else
            Map.get(socket.assigns.versions_map, version_id)
          end

        socket
        |> assign(:selected_version_id, version_id)
        |> assign_source_graph(source)
        |> assign(:can_run?, length(Map.get(source || %{}, :nodes) || []) > 0)
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

    socket =
      socket
      |> assign(:selected_node_id, selected)
      |> maybe_update_presence_selection(selected)

    {:noreply, socket}
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
    socket =
      socket
      |> assign(:selected_node_id, nil)
      |> maybe_update_presence_selection(nil)

    {:noreply, socket}
  end

  # ============================================================================
  # Pin Management Events
  # ============================================================================

  @impl true
  def handle_event("clear_pin", %{"node-id" => node_id}, socket) do
    case apply_edit_operation(socket, :unpin_node_output, %{node_id: node_id}) do
      {:ok, socket} ->
        socket =
          socket
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
    pins = socket.assigns.pins_with_status

    {socket, errors} =
      Enum.reduce(pins, {socket, []}, fn {node_id, _pin}, {socket, errors} ->
        case apply_edit_operation(socket, :unpin_node_output, %{node_id: node_id}) do
          {:ok, socket} -> {socket, errors}
          {:error, reason} -> {socket, [reason | errors]}
        end
      end)

    socket =
      socket
      |> assign(:show_context_menu, false)
      |> put_flash(:info, if(errors == [], do: "All pins cleared", else: "Cleared some pins"))

    {:noreply, socket}
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
             parse_input_payload(input_string, socket.assigns.demo_inputs) do
        with :ok <- maybe_persist_draft_for_run(socket, version_id) do
          execution_attrs =
            %{
              workflow_id: workflow.id,
              execution_type: execution_type_for(version_id),
              trigger: %{type: :manual, data: parsed.trigger_data},
              metadata: build_manual_metadata(parsed.demo_label, version_id: version_id)
            }
            |> maybe_put_workflow_version(version_id)

          case Executions.create_execution(scope, execution_attrs) do
            {:ok, execution} ->
              case ExecutionSupervisor.start_execution(execution.id) do
                {:ok, _pid} ->
                  :ok

                {:error, {:already_started, _pid}} ->
                  :ok

                {:error, reason} ->
                  {:error, reason}
              end
              |> case do
                :ok ->
                  run_form = build_run_form(input_string, version_id: version_id)

                  socket =
                    socket
                    |> maybe_subscribe_to_execution(execution.id)
                    |> assign(:execution, execution)
                    |> assign(:running?, true)
                    |> assign(
                      :node_states,
                      build_initial_pin_states(workflow, socket.assigns.pins_with_status)
                    )
                    |> assign(:trace_log_count, 0)
                    |> assign(:selected_demo, parsed.demo)
                    |> assign(:run_form, run_form)
                    |> assign(:run_form_error, nil)
                    |> stream(:trace_log, [], reset: true)
                    |> append_trace_log(:info, "Execution started", %{
                      execution_id: short_id(execution.id),
                      version: version_id
                    })
                    |> push_patch(
                      to: ~p"/workflows/#{workflow.id}/edit?execution_id=#{execution.id}"
                    )

                  {:noreply, socket}

                {:error, reason} ->
                  {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
              end

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
          end
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to sync draft: #{format_error(reason)}")}
        end
      else
        {:error, :invalid_payload, message} ->
          {:noreply,
           socket
           |> assign(
             :run_form,
             build_run_form(input_string, version_id: version_id, errors: [data: {message, []}])
           )
           |> assign(:run_form_error, message)}
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

    execution_attrs =
      %{
        workflow_id: workflow.id,
        execution_type: :partial,
        trigger: %{type: :manual, data: trigger_data},
        metadata:
          build_manual_metadata("Partial Run: #{node_id}",
            version_id: version_id,
            partial: true,
            target: node_id
          )
      }
      |> maybe_put_workflow_version(version_id)

    with :ok <- maybe_persist_draft_for_run(socket, version_id),
         {:ok, execution} <- Executions.create_execution(scope, execution_attrs) do
      case ExecutionSupervisor.start_execution(execution.id) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
      |> case do
        :ok ->
          socket =
            socket
            |> maybe_subscribe_to_execution(execution.id)
            |> assign(:execution, execution)
            |> assign(:running?, true)
            |> assign(
              :node_states,
              build_initial_pin_states(workflow, socket.assigns.pins_with_status)
            )
            |> assign(:trace_log_count, 0)
            |> stream(:trace_log, [], reset: true)
            |> append_trace_log(:info, "Partial execution started", %{
              partial: true,
              target: node_id,
              version: version_id
            })
            |> push_patch(to: ~p"/workflows/#{workflow.id}/edit?execution_id=#{execution.id}")
            |> assign(:show_context_menu, false)

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Execution failed: #{format_error(reason)}")}
      end
    else
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
     |> release_node_lock()
     |> assign(:show_config_modal, false)
     |> assign(:config_modal_node, nil)
     |> maybe_update_presence_focus(nil)}
  end

  @impl true
  def handle_info({:node_config_saved, node_id, new_config}, socket) do
    node = Map.get(socket.assigns.node_map, node_id)

    if node do
      patch = build_config_patch(node.config || %{}, new_config || %{})

      if patch == [] do
        {:noreply,
         socket
         |> release_node_lock()
         |> assign(:show_config_modal, false)
         |> assign(:config_modal_node, nil)
         |> maybe_update_presence_focus(nil)}
      else
        case apply_edit_operation(socket, :update_node_config, %{node_id: node_id, patch: patch}) do
          {:ok, socket} ->
            socket =
              socket
              |> release_node_lock()
              |> assign(:show_config_modal, false)
              |> assign(:config_modal_node, nil)
              |> maybe_update_presence_focus(nil)
              |> put_flash(:info, "Node configuration saved")
              |> append_trace_log(:info, "Node config updated", %{node_id: short_id(node_id)})

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save: #{format_error(reason)}")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_info({:pin_node_output, node_id, output_data, label}, socket) do
    payload = %{
      node_id: node_id,
      output_data: output_data,
      label: if(label == "", do: nil, else: label)
    }

    case apply_edit_operation(socket, :pin_node_output, payload) do
      {:ok, socket} ->
        socket =
          socket
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
    socket =
      socket
      |> assign(:execution, execution)
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
  def handle_info({:operation_applied, operation}, socket) do
    {:noreply, apply_operation_to_socket(socket, operation)}
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

    socket =
      socket
      |> assign(:node_states, node_states)
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

  defp edit_session_topic(workflow_id), do: "edit_session:#{workflow_id}"

  defp maybe_subscribe_to_edit_session(socket, scope, workflow_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Imgd.PubSub, edit_session_topic(workflow_id))

      _ =
        case scope do
          %{user: user} when not is_nil(user) -> Presence.track_user(workflow_id, user, socket)
          _ -> :ok
        end

      assign(socket, :presence_tracked?, true)
    else
      socket
    end
  end

  defp maybe_update_presence_selection(socket, selected_node_id) do
    if socket.assigns.presence_tracked? do
      node_ids = if selected_node_id, do: [selected_node_id], else: []

      _ =
        Presence.update_selection(
          socket.assigns.workflow.id,
          socket.assigns.current_scope.user.id,
          node_ids
        )
    end

    socket
  end

  defp maybe_update_presence_focus(socket, node_id) do
    if socket.assigns.presence_tracked? do
      user_id = socket.assigns.current_scope.user.id

      case node_id do
        nil -> Presence.clear_focus(socket.assigns.workflow.id, user_id)
        _ -> Presence.update_focus(socket.assigns.workflow.id, user_id, node_id)
      end
    end

    socket
  end

  defp acquire_node_lock(socket, node_id) do
    workflow_id = socket.assigns.workflow.id
    user_id = socket.assigns.current_scope.user.id

    case Server.acquire_node_lock(workflow_id, node_id, user_id) do
      :ok -> {:ok, assign(socket, :locked_node_id, node_id)}
      {:error, _} = error -> error
    end
  end

  defp release_node_lock(socket) do
    case socket.assigns.locked_node_id do
      nil ->
        socket

      node_id ->
        workflow_id = socket.assigns.workflow.id
        user_id = socket.assigns.current_scope.user.id
        Server.release_node_lock(workflow_id, node_id, user_id)
        assign(socket, :locked_node_id, nil)
    end
  end

  defp sync_state_to_draft(%{type: :full_sync, draft: draft, seq: seq}, _workflow) do
    {draft, seq}
  end

  defp sync_state_to_draft(%{type: :incremental, seq: seq}, workflow) do
    {workflow.draft || %Imgd.Workflows.WorkflowDraft{}, seq}
  end

  defp sync_state_to_draft(%{type: :up_to_date, seq: seq}, workflow) do
    {workflow.draft || %Imgd.Workflows.WorkflowDraft{}, seq}
  end

  defp sync_state_to_draft(_state, workflow) do
    {workflow.draft || %Imgd.Workflows.WorkflowDraft{}, 0}
  end

  defp build_pins_with_status(%EditorState{} = editor_state, node_map, pin_labels) do
    editor_state.pinned_outputs
    |> Enum.map(fn {node_id, output_data} ->
      node = Map.get(node_map, node_id)
      label = Map.get(pin_labels, node_id) || (node && node.name)

      {node_id,
       %{
         "data" => output_data,
         "label" => label,
         "pinned_at" => nil,
         "stale" => false,
         "node_exists" => not is_nil(node)
       }}
    end)
    |> Map.new()
  end

  defp maybe_subscribe_to_execution(socket, execution_id) when is_binary(execution_id) do
    current_id = socket.assigns.subscribed_execution_id

    cond do
      current_id == execution_id ->
        socket

      true ->
        if current_id do
          PubSub.unsubscribe_execution(current_id)
        end

        PubSub.subscribe_execution(socket.assigns.current_scope, execution_id)
        assign(socket, :subscribed_execution_id, execution_id)
    end
  end

  defp maybe_subscribe_to_execution(socket, _execution_id), do: socket

  defp apply_edit_operation(socket, type, payload) do
    workflow_id = socket.assigns.workflow.id
    user_id = socket.assigns.current_scope.user.id
    client_seq = socket.assigns.client_seq + 1

    operation = %{
      id: Ecto.UUID.generate(),
      type: type,
      payload: payload,
      user_id: user_id,
      client_seq: client_seq
    }

    case Server.apply_operation(workflow_id, operation) do
      {:ok, _result} ->
        {:ok, assign(socket, :client_seq, client_seq)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_operation_to_socket(socket, operation) do
    type = normalize_operation_type(Map.get(operation, :type) || Map.get(operation, "type"))
    payload = Map.get(operation, :payload) || Map.get(operation, "payload") || %{}
    seq = Map.get(operation, :seq) || Map.get(operation, "seq")

    draft_source = socket.assigns.draft || %Imgd.Workflows.WorkflowDraft{}
    {draft, draft_changed?} = apply_draft_operation(draft_source, type, payload)
    editor_state = apply_editor_state_operation(socket.assigns.editor_state, type, payload)
    pin_labels = update_pin_labels(socket.assigns.pin_labels, type, payload)

    socket =
      socket
      |> assign(:editor_state, editor_state)
      |> assign(:pin_labels, pin_labels)
      |> assign(:edit_session_seq, seq || socket.assigns.edit_session_seq)

    socket =
      if draft_changed? do
        socket
        |> assign(:draft, draft)
        |> assign_source_graph(draft)
        |> assign(:can_run?, length((draft && draft.nodes) || []) > 0)
        |> reconcile_node_refs()
      else
        assign(socket, :draft, draft)
      end

    pins_with_status = build_pins_with_status(editor_state, socket.assigns.node_map, pin_labels)
    assign(socket, :pins_with_status, pins_with_status)
  end

  defp apply_draft_operation(draft, type, payload) do
    if type in @draft_operation_types do
      case Operations.apply(draft, %{type: type, payload: payload}) do
        {:ok, updated_draft} -> {updated_draft, true}
        {:error, _reason} -> {draft, false}
      end
    else
      {draft, false}
    end
  end

  defp apply_editor_state_operation(editor_state, :pin_node_output, payload) do
    node_id = payload_value(payload, :node_id)
    output_data = payload_value(payload, :output_data) || payload_value(payload, :data)

    if node_id do
      EditorState.pin_output(editor_state, node_id, output_data)
    else
      editor_state
    end
  end

  defp apply_editor_state_operation(editor_state, :unpin_node_output, payload) do
    case payload_value(payload, :node_id) do
      nil -> editor_state
      node_id -> EditorState.unpin_output(editor_state, node_id)
    end
  end

  defp apply_editor_state_operation(editor_state, :disable_node, payload) do
    node_id = payload_value(payload, :node_id)
    mode = payload_value(payload, :mode) || :skip

    if node_id do
      EditorState.disable_node(editor_state, node_id, mode)
    else
      editor_state
    end
  end

  defp apply_editor_state_operation(editor_state, :enable_node, payload) do
    case payload_value(payload, :node_id) do
      nil -> editor_state
      node_id -> EditorState.enable_node(editor_state, node_id)
    end
  end

  defp apply_editor_state_operation(editor_state, _type, _payload), do: editor_state

  defp update_pin_labels(pin_labels, :pin_node_output, payload) do
    node_id = payload_value(payload, :node_id)
    label = payload_value(payload, :label)

    cond do
      is_nil(node_id) -> pin_labels
      is_binary(label) and label != "" -> Map.put(pin_labels, node_id, label)
      true -> pin_labels
    end
  end

  defp update_pin_labels(pin_labels, :unpin_node_output, payload) do
    case payload_value(payload, :node_id) do
      nil -> pin_labels
      node_id -> Map.delete(pin_labels, node_id)
    end
  end

  defp update_pin_labels(pin_labels, _type, _payload), do: pin_labels

  defp normalize_operation_type(type) when is_atom(type), do: type
  defp normalize_operation_type("add_node"), do: :add_node
  defp normalize_operation_type("remove_node"), do: :remove_node
  defp normalize_operation_type("update_node_config"), do: :update_node_config
  defp normalize_operation_type("update_node_position"), do: :update_node_position
  defp normalize_operation_type("update_node_metadata"), do: :update_node_metadata
  defp normalize_operation_type("add_connection"), do: :add_connection
  defp normalize_operation_type("remove_connection"), do: :remove_connection
  defp normalize_operation_type("pin_node_output"), do: :pin_node_output
  defp normalize_operation_type("unpin_node_output"), do: :unpin_node_output
  defp normalize_operation_type("disable_node"), do: :disable_node
  defp normalize_operation_type("enable_node"), do: :enable_node
  defp normalize_operation_type(type), do: type

  defp payload_value(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, to_string(key))
    end
  end

  defp reconcile_node_refs(socket) do
    node_map = socket.assigns.node_map

    socket =
      case socket.assigns.selected_node_id do
        nil ->
          socket

        node_id ->
          if Map.has_key?(node_map, node_id) do
            socket
          else
            socket
            |> assign(:selected_node_id, nil)
            |> maybe_update_presence_selection(nil)
          end
      end

    socket =
      case socket.assigns.context_menu_node_id do
        nil ->
          socket

        node_id ->
          if Map.has_key?(node_map, node_id) do
            socket
          else
            socket
            |> assign(:show_context_menu, false)
            |> assign(:context_menu_node_id, nil)
          end
      end

    socket =
      case socket.assigns.config_modal_node do
        nil ->
          socket

        %{id: node_id} ->
          case Map.get(node_map, node_id) do
            nil ->
              socket
              |> release_node_lock()
              |> assign(:show_config_modal, false)
              |> assign(:config_modal_node, nil)
              |> maybe_update_presence_focus(nil)

            updated_node ->
              assign(socket, :config_modal_node, updated_node)
          end
      end

    socket
  end

  defp execution_version_id(execution) do
    version_id =
      Map.get(execution, :workflow_version_id) ||
        (execution.workflow_version && execution.workflow_version.id)

    extras =
      case Map.get(execution, :metadata) do
        %{extras: extras} when is_map(extras) -> extras
        _ -> %{}
      end

    version_id || Map.get(extras, "version_id") || Map.get(extras, :version_id) || "draft"
  end

  defp execution_type_for("draft"), do: :preview
  defp execution_type_for(nil), do: :preview
  defp execution_type_for(_), do: :production

  defp maybe_put_workflow_version(attrs, "draft"), do: attrs
  defp maybe_put_workflow_version(attrs, nil), do: attrs

  defp maybe_put_workflow_version(attrs, version_id),
    do: Map.put(attrs, :workflow_version_id, version_id)

  defp maybe_persist_draft_for_run(socket, "draft") do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    draft = socket.assigns.draft || %Imgd.Workflows.WorkflowDraft{}

    attrs = %{
      nodes: Enum.map(draft.nodes || [], &Map.from_struct/1),
      connections: Enum.map(draft.connections || [], &Map.from_struct/1),
      triggers: Enum.map(draft.triggers || [], &Map.from_struct/1),
      settings: draft.settings || %{}
    }

    case Workflows.update_workflow_draft(scope, workflow, attrs) do
      {:ok, _draft} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_persist_draft_for_run(_socket, _version_id), do: :ok

  defp build_config_patch(old_config, new_config) do
    old_config = normalize_config_keys(old_config)
    new_config = normalize_config_keys(new_config)

    keys =
      old_config
      |> Map.keys()
      |> Kernel.++(Map.keys(new_config))
      |> Enum.uniq()

    Enum.reduce(keys, [], fn key, acc ->
      old_value = Map.get(old_config, key)
      new_value = Map.get(new_config, key)

      cond do
        is_nil(new_value) and Map.has_key?(old_config, key) ->
          [%{"op" => "remove", "path" => "/#{key}"} | acc]

        not Map.has_key?(old_config, key) ->
          [%{"op" => "add", "path" => "/#{key}", "value" => new_value} | acc]

        old_value != new_value ->
          [%{"op" => "replace", "path" => "/#{key}", "value" => new_value} | acc]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_config_keys(config) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_config_keys(_config), do: %{}

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

  defp build_initial_pin_states(_workflow, pins_with_status) do
    pins_with_status
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

  defp build_manual_metadata(label, opts) do
    extras =
      %{"runner" => "manual_live"}
      |> maybe_put_extra("demo_input", label)
      |> maybe_put_extra("version_id", Keyword.get(opts, :version_id))
      |> maybe_put_extra("partial", Keyword.get(opts, :partial))
      |> maybe_put_extra("target_node_id", Keyword.get(opts, :target))

    %{extras: extras}
  end

  defp maybe_put_extra(extras, _key, nil), do: extras
  defp maybe_put_extra(extras, _key, ""), do: extras
  defp maybe_put_extra(extras, key, value), do: Map.put(extras, key, value)

  defp build_run_form(payload, opts) when is_binary(payload) do
    version_id = Keyword.get(opts, :version_id, "draft")
    to_form(%{"data" => payload, "version_id" => version_id}, Keyword.merge([as: :run], opts))
  end

  defp build_run_form(payload, opts), do: payload |> encode_payload() |> build_run_form(opts)

  defp workflow_demo_inputs(workflow) do
    workflow = Imgd.Repo.preload(workflow, :draft)
    settings = (workflow.draft && workflow.draft.settings) || %{}

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
    workflow = Imgd.Repo.preload(workflow, :draft)
    draft = workflow.draft || %Imgd.Workflows.WorkflowDraft{}
    nodes = draft.nodes || []
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
    workflow = Imgd.Repo.preload(workflow, :draft)
    draft = workflow.draft || %Imgd.Workflows.WorkflowDraft{}

    Enum.any?(draft.triggers || [], fn trigger ->
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
          execution={@execution}
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
          pinned={Map.has_key?(@pins_with_status || %{}, @context_menu_node_id)}
          pin_stale={(pin_status && pin_status["stale"]) || false}
          has_output={get_in(@node_states, [@context_menu_node_id, :output_data]) != nil}
          position={@context_menu_position}
        />
      <% end %>
    </Layouts.app>
    """
  end
end
