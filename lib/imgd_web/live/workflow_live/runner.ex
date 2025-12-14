defmodule ImgdWeb.WorkflowLive.Runner do
  @moduledoc """
  LiveView for running and observing workflow executions in real-time.

  Features:
  - Visual DAG representation with live node status updates
  - Real-time trace log streaming
  - Node input/output inspection
  - Execution controls and status
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Executions
  alias Imgd.Executions.{Execution, PubSub}
  alias Imgd.Workflows.DagLayout
  import ImgdWeb.Formatters

  @trace_log_limit 500
  @raw_input_key "__imgd_raw_input__"

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
        # Compute DAG layout
        {layout, layout_meta} =
          DagLayout.compute_with_metadata(workflow.nodes || [], workflow.connections || [])

        edges = DagLayout.compute_edges(workflow.connections || [], layout)

        # Build node map for quick lookup
        node_map = Map.new(workflow.nodes || [], &{&1.id, &1})

        demo_inputs = workflow_demo_inputs(workflow)
        initial_demo = List.first(demo_inputs)
        initial_payload = if(initial_demo, do: initial_demo.data, else: %{})
        run_form = build_run_form(initial_payload)

        socket =
          socket
          |> assign(:page_title, "Run: #{workflow.name}")
          |> assign(:workflow, workflow)
          |> assign(:node_map, node_map)
          |> assign(:dag_layout, layout)
          |> assign(:dag_edges, edges)
          |> assign(:dag_meta, layout_meta)
          |> assign(:execution, nil)
          |> assign(:node_states, %{})
          |> assign(:selected_node_id, nil)
          |> assign(:running?, false)
          |> assign(:can_run?, workflow.published_version_id != nil)
          |> assign(:trace_log_count, 0)
          |> assign(:demo_inputs, demo_inputs)
          |> assign(:selected_demo, initial_demo)
          |> assign(:run_form, run_form)
          |> assign(:run_form_error, nil)
          |> stream(:trace_log, [], dom_id: &"trace-#{&1.id}")

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"execution_id" => execution_id}, _uri, socket) do
    scope = socket.assigns.current_scope

    case Executions.get_execution(scope, execution_id, preload: [:node_executions]) do
      nil ->
        {:noreply, put_flash(socket, :error, "Execution not found")}

      execution ->
        # Subscribe to this execution's updates
        PubSub.subscribe_execution(execution.id)

        # Rebuild state from existing execution
        node_states = build_node_states_from_execution(execution)

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:node_states, node_states)
          |> assign(:running?, Execution.active?(execution))
          |> maybe_stream_existing_logs(execution)

        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("run_workflow", params, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    run_params = Map.get(params, "run", %{})
    input_string = Map.get(run_params, "data", "")

    if socket.assigns.can_run? do
      with {:ok, parsed} <-
             parse_input_payload(input_string, socket.assigns.demo_inputs, @raw_input_key),
           {:ok, %{execution: execution}} <-
             Executions.start_and_enqueue_execution(scope, workflow, %{
               trigger: %{type: :manual, data: parsed.trigger_data},
               metadata: build_manual_metadata(parsed.demo_label)
             }) do
        # Subscribe to execution updates
        PubSub.subscribe_execution(execution.id)

        run_form = build_run_form(input_string)

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:running?, true)
          |> assign(:node_states, %{})
          |> assign(:trace_log_count, 0)
          |> assign(:selected_demo, parsed.demo)
          |> assign(:run_form, run_form)
          |> assign(:run_form_error, nil)
          |> stream(:trace_log, [], reset: true)
          |> append_trace_log(:info, "Execution started", %{execution_id: execution.id})
          |> push_patch(to: ~p"/workflows/#{workflow.id}/run?execution_id=#{execution.id}")

        {:noreply, socket}
      else
        {:error, :invalid_payload, message} ->
          {:noreply,
           socket
           |> assign(:run_form, build_run_form(input_string, errors: [data: {message, []}]))
           |> assign(:run_form_error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Workflow must be published before running")}
    end
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
  def handle_event("update_payload", %{"run" => %{"data" => data}}, socket) do
    data = data || ""

    socket =
      socket
      |> assign(:run_form, build_run_form(data))
      |> maybe_reset_selected_demo(data)
      |> assign(:run_form_error, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    selected = if socket.assigns.selected_node_id == node_id, do: nil, else: node_id
    {:noreply, assign(socket, :selected_node_id, selected)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_node_id, nil)}
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  @impl true
  def handle_info({:execution_started, execution}, socket) do
    socket =
      socket
      |> assign(:execution, execution)
      |> assign(:running?, true)
      |> append_trace_log(:info, "Execution started", %{status: execution.status})

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
        duration_ms: Execution.duration_ms(execution)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execution_failed, execution, error}, socket) do
    socket =
      socket
      |> assign(:execution, execution)
      |> assign(:running?, false)
      |> append_trace_log(:error, "Execution failed", error)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_started, payload}, socket) do
    node_states =
      Map.put(socket.assigns.node_states, payload.node_id, %{
        status: :running,
        started_at: payload.started_at,
        input_data: payload.input_data
      })

    socket =
      socket
      |> assign(:node_states, node_states)
      |> append_trace_log(:info, "Node started: #{payload.node_id}", %{
        node_type: payload.node_type_id
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_completed, payload}, socket) do
    existing = Map.get(socket.assigns.node_states, payload.node_id, %{})

    node_states =
      Map.put(socket.assigns.node_states, payload.node_id, %{
        status: :completed,
        started_at: existing[:started_at] || payload.started_at,
        completed_at: payload.completed_at,
        duration_ms: payload.duration_ms,
        input_data: existing[:input_data] || payload.input_data,
        output_data: payload.output_data
      })

    socket =
      socket
      |> assign(:node_states, node_states)
      |> append_trace_log(:success, "Node completed: #{payload.node_id}", %{
        duration_ms: payload.duration_ms
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_failed, payload}, socket) do
    existing = Map.get(socket.assigns.node_states, payload.node_id, %{})

    node_states =
      Map.put(socket.assigns.node_states, payload.node_id, %{
        status: :failed,
        started_at: existing[:started_at] || payload.started_at,
        completed_at: payload.completed_at,
        input_data: existing[:input_data] || payload.input_data,
        error: payload.error
      })

    socket =
      socket
      |> assign(:node_states, node_states)
      |> append_trace_log(:error, "Node failed: #{payload.node_id}", payload.error)

    {:noreply, socket}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp parse_input_payload(input_string, demo_inputs, raw_key) do
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
            other -> %{raw_key => other}
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

  defp build_manual_metadata(nil) do
    %{extras: %{"runner" => "manual_live"}}
  end

  defp build_manual_metadata(label) do
    %{extras: %{"runner" => "manual_live", "demo_input" => label}}
  end

  defp build_run_form(payload, opts \\ [])

  defp build_run_form(payload, opts) when is_binary(payload) do
    to_form(%{"data" => payload}, Keyword.merge([as: :run], opts))
  end

  defp build_run_form(payload, opts) do
    payload
    |> encode_payload()
    |> build_run_form(opts)
  end

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

    if inputs == [] do
      [default_empty_demo()]
    else
      inputs
    end
  end

  defp default_empty_demo do
    normalize_demo_input(%{
      label: "Empty payload",
      description: "Use when the workflow does not require input data",
      data: %{}
    })
  end

  defp normalize_demo_inputs(list) when is_list(list) do
    list
    |> Enum.map(&normalize_demo_input/1)
    |> Enum.filter(& &1)
  end

  defp normalize_demo_inputs(map) when is_map(map), do: [normalize_demo_input(map)]
  defp normalize_demo_inputs(_), do: []

  defp normalize_demo_input(nil), do: nil

  defp normalize_demo_input(map) when is_map(map) do
    label = Map.get(map, :label) || Map.get(map, "label") || "Preset"

    data =
      map
      |> Map.get(:data)
      |> case do
        nil -> Map.get(map, "data")
        value -> value
      end
      |> case do
        nil -> %{}
        value -> value
      end
      |> normalize_demo_value()

    description = Map.get(map, :description) || Map.get(map, "description")

    %{
      id: demo_id(label, data),
      label: label,
      description: description,
      data: data
    }
  end

  defp demo_id(label, data) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    base = if slug == "", do: "demo", else: slug
    hash = :erlang.phash2(data)

    "#{base}-#{hash}"
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
         duration_ms: Imgd.Executions.NodeExecution.duration_ms(ne),
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
                  data: %{
                    duration_ms: Imgd.Executions.NodeExecution.duration_ms(ne)
                  }
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
        message = "Execution #{execution.status}"

        [
          %{
            id: "exec-end-#{execution.id}",
            level: level,
            message: message,
            timestamp: execution.completed_at,
            data: %{duration_ms: Execution.duration_ms(execution)}
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
      />

      <div class="grid grid-cols-1 xl:grid-cols-3 gap-6">
        <%!-- DAG Visualization --%>
        <div class="xl:col-span-2">
          <.dag_panel
            workflow={@workflow}
            layout={@dag_layout}
            edges={@dag_edges}
            meta={@dag_meta}
            node_map={@node_map}
            node_states={@node_states}
            selected_node_id={@selected_node_id}
          />
        </div>

        <%!-- Right Panel: Node Details + Trace Log --%>
        <div class="space-y-6">
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

      <%!-- Execution Metadata (bottom) --%>
      <.execution_metadata_panel :if={@execution} execution={@execution} />
    </Layouts.app>
    """
  end

  # ============================================================================
  # Component: Execution Status Badge
  # ============================================================================

  defp execution_status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%= if @execution do %>
        <span class={["badge", execution_badge_class(@execution.status)]}>
          {@execution.status}
        </span>
      <% else %>
        <span class="badge badge-ghost">Ready</span>
      <% end %>
    </div>
    """
  end

  defp execution_badge_class(:pending), do: "badge-warning"
  defp execution_badge_class(:running), do: "badge-info"
  defp execution_badge_class(:completed), do: "badge-success"
  defp execution_badge_class(:failed), do: "badge-error"
  defp execution_badge_class(:cancelled), do: "badge-neutral"
  defp execution_badge_class(:timeout), do: "badge-error"
  defp execution_badge_class(_), do: "badge-ghost"

  # ============================================================================
  # Component: Run Panel
  # ============================================================================

  attr :run_form, :map, required: true
  attr :demo_inputs, :list, default: []
  attr :selected_demo, :map, default: nil
  attr :running?, :boolean, default: false
  attr :can_run?, :boolean, default: true
  attr :run_form_error, :string, default: nil

  defp run_panel(assigns) do
    ~H"""
    <.form
      for={@run_form}
      id="run-config-form"
      phx-change="update_payload"
      phx-submit="run_workflow"
      class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 mb-6"
    >
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="flex items-center justify-center w-10 h-10 rounded-xl bg-primary/10 text-primary">
            <.icon name="hero-rocket-launch" class="size-5" />
          </div>
          <div class="space-y-0.5">
            <p class="text-sm font-semibold text-base-content">Manual Run Input</p>
            <p class="text-xs text-base-content/60">
              Provide JSON for your trigger payload or load one of the demo presets.
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="badge badge-ghost badge-sm">Trigger: Manual</span>
          <span class={["badge badge-sm", @running? && "badge-info", @running? || "badge-ghost"]}>
            {(@running? && "Running") || "Ready"}
          </span>
        </div>
      </div>

      <div class="p-4 space-y-4">
        <div class="grid grid-cols-1 xl:grid-cols-3 gap-4">
          <div class="xl:col-span-2 space-y-2">
            <.input
              field={@run_form[:data]}
              type="textarea"
              label="Initial data (JSON)"
              rows="8"
              spellcheck="false"
              class="textarea w-full font-mono text-sm leading-relaxed"
              placeholder='{"user_id": 1}'
            />
            <div class="flex items-center justify-between text-xs text-base-content/60">
              <span>Blank value sends an empty map. Scalars are supported (e.g. 42, "hello").</span>
              <span :if={@run_form_error} class="text-error font-medium">
                {@run_form_error}
              </span>
            </div>
          </div>

          <div class="space-y-3">
            <div class="flex items-center gap-2 text-sm font-semibold text-base-content">
              <.icon name="hero-sparkles" class="size-4 opacity-70" />
              <span>Demo payloads</span>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={demo <- @demo_inputs}
                type="button"
                class={[
                  "btn btn-outline btn-xs",
                  @selected_demo && @selected_demo.id == demo.id && "btn-primary"
                ]}
                phx-click="select_demo_input"
                phx-value-id={demo.id}
                title={demo.description || "Load preset input"}
              >
                {demo.label}
              </button>
            </div>

            <div class="rounded-xl bg-base-200/60 border border-base-200 p-3 space-y-2">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                Selected preset
              </p>
              <%= if @selected_demo do %>
                <p class="text-sm text-base-content">{@selected_demo.label}</p>
                <p :if={@selected_demo.description} class="text-xs text-base-content/60">
                  {@selected_demo.description}
                </p>
                <pre class="mt-2 max-h-32 overflow-auto rounded-lg bg-base-300/50 p-2 text-[11px] font-mono"><%=
                  format_json_preview(@selected_demo.data)
                %></pre>
              <% else %>
                <p class="text-xs text-base-content/60">Start typing or pick a preset.</p>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div class="flex items-center gap-2 text-xs text-base-content/70">
            <.icon name="hero-light-bulb" class="size-4" />
            <span>
              Payload is passed to the first node as trigger input. Use numbers, strings, objects, or arrays.
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="submit"
              class={[
                "btn btn-primary btn-sm gap-2",
                (@running? or not @can_run?) && "btn-disabled"
              ]}
              disabled={@running? or not @can_run?}
            >
              <.icon
                name={if @running?, do: "hero-arrow-path", else: "hero-play"}
                class={"size-4#{if @running?, do: " animate-spin", else: ""}"}
              />
              <span>{if @running?, do: "Running...", else: "Run workflow"}</span>
            </button>
            <span :if={not @can_run?} class="text-xs text-warning">
              Publish the workflow to enable runs.
            </span>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  # ============================================================================
  # Component: DAG Panel
  # ============================================================================

  defp dag_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 overflow-hidden">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-squares-2x2" class="size-4 opacity-70" /> Workflow Graph
        </h2>
        <span class="text-xs text-base-content/60">
          {length(@workflow.nodes || [])} nodes
        </span>
      </div>

      <div class="p-4 overflow-auto bg-base-200/30" style="max-height: 600px;">
        <%= if @workflow.nodes == [] or is_nil(@workflow.nodes) do %>
          <div class="flex flex-col items-center justify-center py-16 text-base-content/60">
            <.icon name="hero-cube-transparent" class="size-12 mb-3 opacity-50" />
            <p class="text-sm">No nodes in this workflow</p>
          </div>
        <% else %>
          <svg
            width={@meta.width}
            height={@meta.height}
            class="mx-auto"
            style="min-width: 100%;"
          >
            <%!-- Edges --%>
            <g class="edges">
              <%= for edge <- @edges do %>
                <path
                  d={edge.path}
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  class="text-base-300"
                  marker-end="url(#arrowhead)"
                />
              <% end %>
            </g>

            <%!-- Arrow marker definition --%>
            <defs>
              <marker
                id="arrowhead"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" fill="currentColor" class="text-base-300" />
              </marker>
            </defs>

            <%!-- Nodes --%>
            <g class="nodes">
              <%= for node <- @workflow.nodes || [] do %>
                <% pos = Map.get(@layout, node.id, %{x: 0, y: 0}) %>
                <% state = Map.get(@node_states, node.id, %{}) %>
                <.dag_node
                  node={node}
                  position={pos}
                  state={state}
                  selected={@selected_node_id == node.id}
                />
              <% end %>
            </g>
          </svg>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Component: DAG Node
  # ============================================================================

  attr :node, :map, required: true
  attr :position, :map, required: true
  attr :state, :map, required: true
  attr :selected, :boolean, default: false

  defp dag_node(assigns) do
    ~H"""
    <g
      transform={"translate(#{@position.x}, #{@position.y})"}
      phx-click="select_node"
      phx-value-node-id={@node.id}
      class="cursor-pointer"
    >
      <%!-- Node background --%>
      <rect
        width="200"
        height="80"
        rx="12"
        class={[
          "transition-all duration-200",
          node_bg_class(@state[:status], @selected)
        ]}
        stroke-width={if @selected, do: "3", else: "1"}
      />

      <%!-- Status indicator --%>
      <circle
        cx="16"
        cy="16"
        r="6"
        class={node_status_indicator_class(@state[:status])}
      />

      <%!-- Running animation --%>
      <%= if @state[:status] == :running do %>
        <circle cx="16" cy="16" r="6" class="fill-info animate-ping opacity-50" />
      <% end %>

      <%!-- Node name --%>
      <text x="32" y="20" class="text-sm font-medium fill-current" dominant-baseline="middle">
        {truncate_text(@node.name, 20)}
      </text>

      <%!-- Node type --%>
      <text x="16" y="44" class="text-xs fill-current opacity-60">
        {node_type_label(@node.type_id)}
      </text>

      <%!-- Duration if completed --%>
      <%= if @state[:duration_ms] do %>
        <text x="16" y="64" class="text-xs fill-current opacity-50">
          {format_duration(@state[:duration_ms])}
        </text>
      <% end %>

      <%!-- Error indicator --%>
      <%= if @state[:status] == :failed do %>
        <g transform="translate(176, 8)">
          <circle cx="8" cy="8" r="8" class="fill-error" />
          <text x="8" y="12" text-anchor="middle" class="text-xs fill-error-content font-bold">
            !
          </text>
        </g>
      <% end %>
    </g>
    """
  end

  defp node_bg_class(nil, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(nil, true), do: "fill-base-100 stroke-primary"
  defp node_bg_class(:pending, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(:pending, true), do: "fill-base-100 stroke-primary"
  defp node_bg_class(:running, _), do: "fill-info/10 stroke-info"
  defp node_bg_class(:completed, false), do: "fill-success/10 stroke-success"
  defp node_bg_class(:completed, true), do: "fill-success/10 stroke-primary"
  defp node_bg_class(:failed, false), do: "fill-error/10 stroke-error"
  defp node_bg_class(:failed, true), do: "fill-error/10 stroke-primary"
  defp node_bg_class(_, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(_, true), do: "fill-base-100 stroke-primary"

  defp node_status_indicator_class(nil), do: "fill-base-300"
  defp node_status_indicator_class(:pending), do: "fill-warning"
  defp node_status_indicator_class(:running), do: "fill-info"
  defp node_status_indicator_class(:completed), do: "fill-success"
  defp node_status_indicator_class(:failed), do: "fill-error"
  defp node_status_indicator_class(_), do: "fill-base-300"

  defp node_type_label(type_id) do
    type_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp truncate_text(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len - 1) <> "…"
  end

  defp truncate_text(text, _), do: text

  defp format_duration(nil), do: ""
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 2)}s"

  # ============================================================================
  # Component: Node Details Panel
  # ============================================================================

  defp node_details_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-cube" class="size-4 opacity-70" /> Node Details
        </h2>
        <%= if @selected_node_id do %>
          <button
            type="button"
            phx-click="clear_selection"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        <% end %>
      </div>

      <div class="p-4">
        <%= if @selected_node_id do %>
          <% node = Map.get(@node_map, @selected_node_id) %>
          <% state = Map.get(@node_states, @selected_node_id, %{}) %>

          <div class="space-y-4">
            <%!-- Node Info --%>
            <div>
              <h3 class="font-medium text-base-content">{node.name}</h3>
              <p class="text-xs text-base-content/60 mt-1">
                Type: {node_type_label(node.type_id)}
              </p>
              <p class="text-xs font-mono text-base-content/40 mt-1">
                {node.id}
              </p>
            </div>

            <%!-- Status --%>
            <%= if state[:status] do %>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-1">
                  Status
                </p>
                <span class={["badge badge-sm", node_status_badge_class(state[:status])]}>
                  {state[:status]}
                </span>
                <%= if state[:duration_ms] do %>
                  <span class="text-xs text-base-content/60 ml-2">
                    {format_duration(state[:duration_ms])}
                  </span>
                <% end %>
              </div>
            <% end %>

            <%!-- Input Data --%>
            <.data_section title="Input" data={state[:input_data]} />

            <%!-- Output Data --%>
            <.data_section title="Output" data={state[:output_data]} />

            <%!-- Error --%>
            <%= if state[:error] do %>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-error mb-1">
                  Error
                </p>
                <pre class="text-xs bg-error/10 text-error p-2 rounded-lg overflow-auto max-h-32"><%=
                  inspect(state[:error], pretty: true)
                %></pre>
              </div>
            <% end %>

            <%!-- Config --%>
            <.data_section title="Configuration" data={node.config} />
          </div>
        <% else %>
          <div class="text-center py-8 text-base-content/60">
            <.icon name="hero-cursor-arrow-rays" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">Click a node to view details</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp node_status_badge_class(:pending), do: "badge-warning"
  defp node_status_badge_class(:running), do: "badge-info"
  defp node_status_badge_class(:completed), do: "badge-success"
  defp node_status_badge_class(:failed), do: "badge-error"
  defp node_status_badge_class(_), do: "badge-ghost"

  attr :title, :string, required: true
  attr :data, :any, default: nil

  defp data_section(assigns) do
    ~H"""
    <div :if={@data && @data != %{}}>
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-1">
        {@title}
      </p>
      <pre class="text-xs bg-base-200/60 p-2 rounded-lg overflow-auto max-h-40"><%=
        format_json_preview(@data)
      %></pre>
    </div>
    """
  end

  defp format_json_preview(data) when is_map(data) or is_list(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> truncate_json(json, 500)
      _ -> inspect(data, pretty: true, limit: 20)
    end
  end

  defp format_json_preview(data), do: inspect(data, pretty: true, limit: 20)

  defp truncate_json(json, max_len) when byte_size(json) > max_len do
    String.slice(json, 0, max_len) <> "\n... (truncated)"
  end

  defp truncate_json(json, _), do: json

  # ============================================================================
  # Component: Trace Log Panel
  # ============================================================================

  defp trace_log_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-document-text" class="size-4 opacity-70" /> Trace Log
        </h2>
      </div>

      <div
        id="trace-log-container"
        class="p-2 overflow-auto font-mono text-xs"
        style="max-height: 400px;"
        phx-update="stream"
        phx-hook=".ScrollToBottom"
      >
        <div
          :for={{dom_id, entry} <- @trace_log}
          id={dom_id}
          class={["py-1 px-2 rounded", trace_log_entry_class(entry.level)]}
        >
          <span class="text-base-content/40">
            {format_log_timestamp(entry.timestamp)}
          </span>
          <span class={trace_log_level_class(entry.level)}>
            [{entry.level}]
          </span>
          <span class="text-base-content">
            {entry.message}
          </span>
          <%= if entry.data && entry.data != %{} do %>
            <span class="text-base-content/60 ml-1">
              {format_log_data(entry.data)}
            </span>
          <% end %>
        </div>

        <div
          :if={@trace_log_count == 0}
          class="text-center py-8 text-base-content/60"
        >
          <p class="text-sm">No log entries yet</p>
          <p class="text-xs mt-1">Run the workflow to see trace output</p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() {
            this.scrollToBottom()
            this.autoScroll = true

            // Track if user has scrolled up (disable auto-scroll)
            this.el.addEventListener('scroll', () => {
              const { scrollTop, scrollHeight, clientHeight } = this.el
              // Consider "at bottom" if within 50px of bottom
              this.autoScroll = scrollTop + clientHeight >= scrollHeight - 50
            })
          },

          updated() {
            if (this.autoScroll) {
              this.scrollToBottom()
            }
          },

          scrollToBottom() {
            // Use requestAnimationFrame to ensure DOM is updated
            requestAnimationFrame(() => {
              this.el.scrollTop = this.el.scrollHeight
            })
          }
        }
      </script>
    </div>
    """
  end

  defp trace_log_entry_class(:error), do: "bg-error/10"
  defp trace_log_entry_class(:success), do: "bg-success/10"
  defp trace_log_entry_class(_), do: "hover:bg-base-200/50"

  defp trace_log_level_class(:error), do: "text-error font-semibold"
  defp trace_log_level_class(:success), do: "text-success font-semibold"
  defp trace_log_level_class(:warning), do: "text-warning"
  defp trace_log_level_class(_), do: "text-info"

  defp format_log_timestamp(nil), do: "--:--:--"

  defp format_log_timestamp(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_log_data(data) when is_map(data) and map_size(data) == 0, do: ""

  defp format_log_data(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end

  defp format_log_data(_), do: ""

  # ============================================================================
  # Component: Execution Metadata Panel
  # ============================================================================

  defp execution_metadata_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 mt-6">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-information-circle" class="size-4 opacity-70" /> Execution Details
        </h2>
      </div>

      <div class="p-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Execution ID
            </p>
            <p class="text-sm font-mono mt-1">
              <.link navigate={~p"/workflows/#{@workflow.id}/executions/#{@execution.id}"} class="link link-primary">
                {short_id(@execution.id)}
              </.link>
            </p>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Status
            </p>
            <p class="mt-1">
              <span class={["badge badge-sm", execution_badge_class(@execution.status)]}>
                {@execution.status}
              </span>
            </p>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Started
            </p>
            <p class="text-sm mt-1">
              {formatted_timestamp(@execution.started_at)}
            </p>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Duration
            </p>
            <p class="text-sm mt-1">
              {format_duration(Execution.duration_ms(@execution))}
            </p>
          </div>
        </div>

        <%= if @execution.error do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-error mb-2">
              Error Details
            </p>
            <pre class="text-xs bg-error/10 text-error p-3 rounded-lg overflow-auto max-h-40"><%=
              inspect(@execution.error, pretty: true)
            %></pre>
          </div>
        <% end %>

        <%= if @execution.output && @execution.output != %{} do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
              Output
            </p>
            <pre class="text-xs bg-base-200/60 p-3 rounded-lg overflow-auto max-h-40"><%=
              format_json_preview(@execution.output)
            %></pre>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
