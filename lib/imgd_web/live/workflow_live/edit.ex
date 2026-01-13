defmodule ImgdWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for designing and editing workflows with real-time collaboration.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Steps
  alias Imgd.Steps.Registry, as: StepRegistry
  alias Imgd.Collaboration.EditorState
  alias Imgd.Collaboration.EditSession.{Server, Presence, PubSub, Operations}
  alias Imgd.Executions
  alias Imgd.Executions.Execution
  alias Imgd.Executions.PubSub, as: ExecutionPubSub
  alias Imgd.Runtime.Execution.Supervisor, as: ExecutionSupervisor
  alias Imgd.Runtime.RunicAdapter
  alias Ecto.UUID
  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    case Workflows.get_workflow_with_draft(id, scope) do
      {:ok, workflow} ->
        case PubSub.authorize_edit(scope, workflow.id) do
          :ok ->
            step_types = Steps.list_types()
            node_library_items = Steps.list_library_items()

            socket =
              socket
              |> assign(:page_title, "Editing #{workflow.name}")
              |> assign(:workflow, workflow)
              |> assign(:step_types, step_types)
              |> assign(:node_library_items, node_library_items)
              |> assign(:editor_state, %EditorState{workflow_id: workflow.id})
              |> assign(:presences, [])
              |> assign(:current_user_id, user.id)
              |> assign(:execution, nil)
              |> assign(:step_executions, [])
              |> assign(:execution_id, nil)
              |> assign(:expression_previews, %{})
              |> assign(:webhook_execution_subscribed, false)

            # Only set up collaboration when WebSocket is connected
            socket =
              if connected?(socket) do
                setup_collaboration(socket, workflow.id, user)
              else
                socket
              end

            {:ok, socket, layout: false}

          {:error, :unauthorized} ->
            socket =
              socket
              |> put_flash(:error, "You do not have permission to edit this workflow")
              |> redirect(to: ~p"/workflows/#{workflow.id}")

            {:ok, socket}
        end

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, "Workflow not found")
          |> redirect(to: ~p"/workflows")

        {:ok, socket}
    end
  end

  # =============================================================================
  # Collaboration Setup
  # =============================================================================

  defp setup_collaboration(socket, workflow_id, user) do
    # Ensure edit session server is running
    {:ok, _pid} = Imgd.Collaboration.EditSession.Supervisor.ensure_session(workflow_id)

    # Subscribe to operation broadcasts
    :ok = Phoenix.PubSub.subscribe(Imgd.PubSub, PubSub.session_topic(workflow_id))

    # Subscribe to presence topic for diffs
    :ok = Phoenix.PubSub.subscribe(Imgd.PubSub, Presence.topic(workflow_id))

    # Track this user's presence
    {:ok, _} = Presence.track_user(workflow_id, user, socket)

    # Get initial editor state
    editor_state =
      case Server.get_editor_state(workflow_id) do
        {:ok, state} -> state
        _ -> %EditorState{workflow_id: workflow_id}
      end

    # Get initial presence list
    presences = format_presences(Presence.list_users(workflow_id))

    {draft, editor_state} =
      case Server.get_sync_state(workflow_id) do
        {:ok, %{type: :full_sync, draft: draft, editor_state: sync_editor_state}} ->
          {draft, deserialize_editor_state(sync_editor_state, workflow_id)}

        _ ->
          {socket.assigns.workflow.draft, editor_state}
      end

    # Get latest execution
    {execution, step_executions} =
      case Executions.list_workflow_executions(
             socket.assigns.current_scope,
             socket.assigns.workflow,
             limit: 1
           ) do
        [latest] ->
          {:ok, full_execution} =
            Executions.get_execution_with_steps(socket.assigns.current_scope, latest.id)

          {full_execution, full_execution.step_executions}

        [] ->
          {nil, []}
      end

    socket
    |> assign(:workflow, %{socket.assigns.workflow | draft: draft})
    |> assign(:editor_state, editor_state)
    |> assign(:presences, presences)
    |> assign(:execution, execution)
    |> assign(:execution_id, if(execution, do: execution.id, else: nil))
    |> assign(:step_executions, step_executions)
    |> maybe_toggle_webhook_subscription(editor_state)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} hide_nav={true} full_bleed={true}>
      <div class="h-screen w-full overflow-hidden bg-base-200">
        <.vue
          v-component="WorkflowEditor"
          v-ssr={false}
          v-socket={@socket}
          workflow={@workflow}
          stepTypes={@step_types}
          nodeLibraryItems={@node_library_items}
          editorState={@editor_state}
          presences={@presences}
          currentUserId={@current_user_id}
          execution={@execution}
          stepExecutions={@step_executions}
          v-on:add_step={JS.push("add_step")}
          v-on:move_step={JS.push("move_step")}
          v-on:update_step={JS.push("update_step")}
          v-on:remove_step={JS.push("remove_step")}
          v-on:add_connection={JS.push("add_connection")}
          v-on:remove_connection={JS.push("remove_connection")}
          v-on:save_workflow={JS.push("save_workflow")}
          v-on:mouse_move={JS.push("mouse_move")}
          v-on:selection_changed={JS.push("selection_changed")}
          v-on:pin_output={JS.push("pin_output")}
          v-on:unpin_output={JS.push("unpin_output")}
          v-on:disable_step={JS.push("disable_step")}
          v-on:enable_step={JS.push("enable_step")}
          v-on:run_test={JS.push("run_test")}
          v-on:cancel_execution={JS.push("cancel_execution")}
          v-on:preview_expression={JS.push("preview_expression")}
          v-on:toggle_webhook_test={JS.push("toggle_webhook_test")}
          expressionPreviews={@expression_previews}
        />
      </div>
    </Layouts.app>
    """
  end

  # =============================================================================
  # Step Operations
  # =============================================================================

  @impl true
  def handle_event("add_step", %{"type_id" => type_id, "position" => pos}, socket) do
    step_type_name =
      case StepRegistry.get(type_id) do
        {:ok, type} -> type.name
        _ -> "Step"
      end

    steps = socket.assigns.workflow.draft.steps || []
    {unique_name, step_id} = Imgd.Workflows.generate_unique_step_identity(steps, step_type_name)

    step = %{
      id: step_id,
      type_id: type_id,
      name: unique_name,
      config: %{},
      position: pos,
      notes: nil
    }

    apply_operation(socket, :add_step, %{step: step})
  end

  @impl true
  def handle_event("move_step", %{"step_id" => step_id, "position" => pos}, socket) do
    apply_operation(socket, :update_step_position, %{step_id: step_id, position: pos})
  end

  @impl true
  def handle_event("update_step", %{"step_id" => step_id, "changes" => changes}, socket) do
    apply_operation(socket, :update_step_metadata, %{step_id: step_id, changes: changes})
  end

  @impl true
  def handle_event("remove_step", %{"step_id" => step_id}, socket) do
    Logger.info("Received remove_step event for step: #{step_id}")
    apply_operation(socket, :remove_step, %{step_id: step_id})
  end

  @impl true
  def handle_event("add_connection", params, socket) do
    connection = %{
      id: UUID.generate(),
      source_step_id: params["source_step_id"],
      target_step_id: params["target_step_id"],
      source_output: params["source_output"] || "main",
      target_input: params["target_input"] || "main"
    }

    apply_operation(socket, :add_connection, %{connection: connection})
  end

  @impl true
  def handle_event("remove_connection", %{"connection_id" => id}, socket) do
    Logger.info("Received remove_connection event for connection: #{id}")
    apply_operation(socket, :remove_connection, %{connection_id: id})
  end

  # =============================================================================
  # Editor State Operations
  # =============================================================================

  @impl true
  def handle_event("pin_output", %{"step_id" => step_id}, socket) do
    apply_operation(socket, :pin_step_output, %{step_id: step_id, output_data: %{}})
  end

  @impl true
  def handle_event("unpin_output", %{"step_id" => step_id}, socket) do
    apply_operation(socket, :unpin_step_output, %{step_id: step_id})
  end

  @impl true
  def handle_event("disable_step", %{"step_id" => step_id, "mode" => mode}, socket) do
    mode_atom = if mode == "exclude", do: :exclude, else: :skip
    apply_operation(socket, :disable_step, %{step_id: step_id, mode: mode_atom})
  end

  @impl true
  def handle_event("enable_step", %{"step_id" => step_id}, socket) do
    apply_operation(socket, :enable_step, %{step_id: step_id})
  end

  # =============================================================================
  # Presence/Collaboration Events
  # =============================================================================

  @impl true
  def handle_event("mouse_move", params, socket) do
    x = params["x"]
    y = params["y"]
    dragging_steps = params["dragging_steps"]

    Presence.update_interaction(
      socket.assigns.workflow.id,
      socket.assigns.current_user_id,
      if(x && y, do: %{x: x, y: y}, else: nil),
      dragging_steps
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("selection_changed", %{"step_ids" => step_ids}, socket) do
    Presence.update_selection(
      socket.assigns.workflow.id,
      socket.assigns.current_user_id,
      step_ids
    )

    {:noreply, socket}
  end

  # =============================================================================
  # Workflow Operations
  # =============================================================================

  @impl true
  def handle_event("save_workflow", _params, socket) do
    case Server.persist_sync(socket.assigns.workflow.id) do
      :ok ->
        socket = refresh_workflow(socket)
        {:noreply, put_flash(socket, :info, "Workflow draft saved")}

      :noop ->
        {:noreply, put_flash(socket, :info, "No draft changes to save")}

      {:error, reason} ->
        Logger.error("Failed to persist workflow draft: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to save workflow draft")}
    end
  end

  @impl true
  def handle_event("run_test", _params, socket) do
    case start_preview_execution(socket) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Test execution started")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to start test: #{reason}")}
    end
  end

  @impl true
  def handle_event(
        "toggle_webhook_test",
        %{"action" => action, "step_id" => step_id} = params,
        socket
      ) do
    workflow_id = socket.assigns.workflow.id

    case action do
      "start" ->
        attrs = %{
          step_id: step_id,
          path: Map.get(params, "path"),
          method: Map.get(params, "method"),
          user_id: socket.assigns.current_user_id
        }

        case Server.enable_test_webhook(workflow_id, attrs) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Unable to enable test webhook: #{format_test_webhook_error(reason)}"
             )}
        end

      "stop" ->
        _ = Server.disable_test_webhook(workflow_id, step_id)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_execution", _params, socket) do
    case socket.assigns.execution do
      %Execution{} = execution ->
        _ = maybe_stop_execution_process(execution.id)

        case Executions.cancel_execution(socket.assigns.current_scope, execution) do
          {:ok, updated_execution} ->
            {:noreply, assign(socket, :execution, updated_execution)}

          {:error, :already_terminal} ->
            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to cancel execution")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "preview_expression",
        %{"expression" => template, "step_id" => step_id, "field_key" => field_key},
        socket
      ) do
    execution = socket.assigns.execution
    step_executions = socket.assigns.step_executions

    # Step ID is now the key-safe slug, no mapping needed
    step_outputs =
      Enum.reduce(step_executions, %{}, fn se, acc ->
        Map.put(acc, se.step_id, se.output_data)
      end)

    current_step_execution = Enum.find(step_executions, fn se -> se.step_id == step_id end)
    current_input = if current_step_execution, do: current_step_execution.input_data, else: nil

    result =
      cond do
        !Imgd.Runtime.Expression.contains_expression?(template) ->
          template

        execution ->
          vars = Imgd.Runtime.Expression.Context.build(execution, step_outputs, current_input)

          case Imgd.Runtime.Expression.evaluate_with_vars(template, vars) do
            {:ok, val} -> to_string(val)
            {:error, reason} -> Map.put(reason, :text, template)
          end

        # Attempt to load the latest execution if nil
        true ->
          case Executions.list_workflow_executions(
                 socket.assigns.current_scope,
                 socket.assigns.workflow,
                 limit: 1
               ) do
            [latest] ->
              {:ok, full_execution} =
                Executions.get_execution_with_steps(socket.assigns.current_scope, latest.id)

              # Step ID is now the key-safe slug, no mapping needed
              so =
                Map.new(full_execution.step_executions, fn se -> {se.step_id, se.output_data} end)

              ci =
                Enum.find(full_execution.step_executions, fn se -> se.step_id == step_id end)
                |> then(fn
                  nil -> nil
                  se -> se.input_data
                end)

              vars = Imgd.Runtime.Expression.Context.build(full_execution, so, ci)

              case Imgd.Runtime.Expression.evaluate_with_vars(template, vars) do
                {:ok, val} -> to_string(val)
                {:error, reason} -> Map.put(reason, :text, template)
              end

            [] ->
              "Run a test to see preview results"
          end
      end

    # Update previews in socket assigns
    previews = socket.assigns.expression_previews
    new_previews = Map.put(previews, "#{step_id}:#{field_key}", result)

    {:noreply, assign(socket, :expression_previews, new_previews)}
  end

  @impl true
  def terminate(_reason, socket) do
    _ = unsubscribe_execution(socket)

    if socket.assigns.webhook_execution_subscribed do
      ExecutionPubSub.unsubscribe_workflow_executions(socket.assigns.workflow.id)
    end

    :ok
  end

  # =============================================================================
  # PubSub Message Handlers
  # =============================================================================

  # Handle operation broadcasts from the edit session server
  @impl true
  def handle_info({:operation_applied, operation}, socket) do
    case Operations.apply(socket.assigns.workflow.draft, operation) do
      {:ok, new_draft} ->
        updated_workflow = %{socket.assigns.workflow | draft: new_draft}
        {:noreply, assign(socket, :workflow, updated_workflow)}

      {:error, reason} ->
        Logger.error(
          "edit.ex: Failed to apply operation #{inspect(operation.type)}: #{inspect(reason)}. Reloading..."
        )

        # Fallback: reload from database
        case Workflows.get_workflow_with_draft(
               socket.assigns.workflow.id,
               socket.assigns.current_scope
             ) do
          {:ok, workflow} ->
            {:noreply, assign(socket, :workflow, workflow)}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # Handle editor state updates (pins, disabled steps, locks)
  @impl true
  def handle_info({:editor_state_updated, new_editor_state}, socket) do
    socket =
      socket
      |> assign(:editor_state, new_editor_state)
      |> maybe_toggle_webhook_subscription(new_editor_state)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:webhook_test_execution, %{execution_id: execution_id}}, socket) do
    case Executions.get_execution(socket.assigns.current_scope, execution_id) do
      {:ok, execution} ->
        {:noreply, switch_to_execution(socket, execution)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # Handle Phoenix.Presence diff broadcasts
  # This is the standard format from Phoenix.Presence
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    handle_presence_diff(socket, diff)
  end

  # Alternative format - plain presence_diff tuple (just in case)
  @impl true
  def handle_info({:presence_diff, diff}, socket) do
    handle_presence_diff(socket, diff)
  end

  # Handle lock events
  @impl true
  def handle_info({:lock_acquired, step_id, user_id}, socket) do
    editor_state =
      EditorState.put_lock(socket.assigns.editor_state, step_id, user_id, DateTime.utc_now())

    {:noreply, assign(socket, :editor_state, editor_state)}
  end

  @impl true
  def handle_info({:lock_released, step_id}, socket) do
    editor_state = EditorState.release_lock(socket.assigns.editor_state, step_id)
    {:noreply, assign(socket, :editor_state, editor_state)}
  end

  # Handle sync state (for reconnection)
  @impl true
  def handle_info({:sync_state, state}, socket) do
    editor_state = deserialize_editor_state(state.editor_state, socket.assigns.workflow.id)

    socket =
      socket
      |> assign(:workflow, %{socket.assigns.workflow | draft: state.draft})
      |> assign(:editor_state, editor_state)
      |> maybe_toggle_webhook_subscription(editor_state)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execution_event, %{execution_id: execution_id} = event}, socket) do
    if execution_id == socket.assigns.execution_id do
      socket =
        if event.type == :execution_failed do
          put_flash(socket, :error, "Execution failed: #{format_error_message(event.data)}")
        else
          socket
        end

      {:noreply, refresh_execution_from_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:execution_started,
         %Execution{execution_type: :preview, trigger: %Execution.Trigger{type: :webhook}} =
           execution},
        socket
      ) do
    if webhook_listening?(socket) do
      {:noreply, switch_to_execution(socket, execution)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:execution_started, %Execution{} = execution}, socket) do
    {:noreply, update_execution_assign(socket, execution)}
  end

  @impl true
  def handle_info({:execution_updated, %Execution{} = execution}, socket) do
    {:noreply, update_execution_assign(socket, execution)}
  end

  @impl true
  def handle_info({:execution_completed, %Execution{} = execution}, socket) do
    {:noreply, update_execution_assign(socket, execution)}
  end

  @impl true
  def handle_info({:execution_failed, %Execution{} = execution, error}, socket) do
    socket = put_flash(socket, :error, "Execution failed: #{format_execution_error(error)}")
    {:noreply, update_execution_assign(socket, execution)}
  end

  @impl true
  def handle_info({event, payload}, socket)
      when event in [:step_started, :step_completed, :step_failed, :step_skipped] do
    socket =
      if event == :step_failed do
        step_id = payload[:step_id] || payload["step_id"]
        error = payload[:error] || payload["error"]
        put_flash(socket, :error, "Step #{step_id} failed: #{format_error_message(error)}")
      else
        socket
      end

    {:noreply, update_step_executions(socket, event, payload)}
  end

  # Catch-all for unhandled messages (useful for debugging)
  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("Unhandled message in WorkflowLive.Edit: #{inspect(msg)}")
    {:noreply, socket}
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp apply_operation(socket, type, payload) do
    operation = %{
      id: UUID.generate(),
      type: type,
      payload: payload,
      user_id: socket.assigns.current_user_id,
      client_seq: nil
    }

    case Server.apply_operation(socket.assigns.workflow.id, operation) do
      {:ok, _result} ->
        {:noreply, socket}

      {:error, reason} ->
        require Logger
        Logger.warning("Operation failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Operation failed")}
    end
  end

  defp refresh_workflow(socket) do
    case Workflows.get_workflow_with_draft(
           socket.assigns.current_scope,
           socket.assigns.workflow.id
         ) do
      {:ok, workflow} -> assign(socket, :workflow, workflow)
      {:error, _} -> socket
    end
  end

  defp webhook_listening?(socket) do
    case socket.assigns.editor_state do
      %EditorState{webhook_test: webhook_test} when not is_nil(webhook_test) -> true
      _ -> false
    end
  end

  defp maybe_toggle_webhook_subscription(socket, %EditorState{} = editor_state) do
    listening? = not is_nil(editor_state.webhook_test)
    subscribed? = socket.assigns.webhook_execution_subscribed

    cond do
      listening? and not subscribed? ->
        case ExecutionPubSub.subscribe_workflow_executions(
               socket.assigns.current_scope,
               socket.assigns.workflow.id
             ) do
          :ok -> assign(socket, :webhook_execution_subscribed, true)
          {:error, _} -> socket
        end

      not listening? and subscribed? ->
        ExecutionPubSub.unsubscribe_workflow_executions(socket.assigns.workflow.id)
        assign(socket, :webhook_execution_subscribed, false)

      true ->
        socket
    end
  end

  defp switch_to_execution(socket, %Execution{} = execution) do
    socket = unsubscribe_execution(socket)
    _ = subscribe_execution(socket.assigns.current_scope, execution.id)

    steps =
      case socket.assigns.workflow.draft do
        nil -> []
        draft -> draft.steps || []
      end

    step_executions = build_initial_step_executions(execution.id, steps)

    socket
    |> assign(:execution, execution)
    |> assign(:execution_id, execution.id)
    |> assign(:step_executions, step_executions)
  end

  defp start_preview_execution(socket) do
    socket = unsubscribe_execution(socket)

    workflow = socket.assigns.workflow
    draft = workflow.draft
    editor_state = socket.assigns.editor_state
    scope = socket.assigns.current_scope

    if is_nil(draft) do
      {:error, "workflow draft missing", socket}
    else
      preview_draft = build_preview_draft(draft, editor_state)
      pinned_outputs = editor_state.pinned_outputs || %{}
      trigger_data = find_trigger_data(preview_draft)

      attrs = %{
        workflow_id: workflow.id,
        execution_type: :preview,
        trigger: %{type: :manual, data: trigger_data},
        metadata: %{
          extras: %{
            preview: true,
            request: %{
              "request_id" => "mock-request-" <> UUID.generate(),
              "headers" => %{"user-agent" => "Imgd Editor (Preview)"},
              "body" => %{}
            }
          }
        }
      }

      with {:ok, execution} <- Executions.create_execution(scope, attrs),
           {:ok, execution} <-
             put_runic_snapshot(scope, execution, preview_draft, pinned_outputs),
           :ok <- subscribe_execution(scope, execution.id),
           {:ok, _pid} <- start_execution_process(execution.id) do
        step_executions = build_initial_step_executions(execution.id, preview_draft.steps)

        socket =
          socket
          |> assign(:execution, execution)
          |> assign(:execution_id, execution.id)
          |> assign(:step_executions, step_executions)

        {:ok, socket}
      else
        {:error, reason} ->
          {:error, format_execution_error(reason), socket}
      end
    end
  end

  defp put_runic_snapshot(scope, %Execution{} = execution, draft, pinned_outputs) do
    metadata = normalize_execution_metadata(execution.metadata)

    runic_workflow =
      RunicAdapter.to_runic_workflow(draft,
        execution_id: execution.id,
        metadata: metadata,
        step_outputs: pinned_outputs,
        trigger_data: execution.trigger.data || %{},
        trigger_type: execution.trigger.type
      )

    snapshot = :erlang.term_to_binary(runic_workflow)
    Executions.put_execution_snapshot(scope, execution, snapshot)
  end

  defp find_trigger_data(draft) do
    # Find the first manual_input step and extract its trigger_data config
    manual_input_step =
      Enum.find(draft.steps, fn step ->
        step.type_id == "manual_input"
      end)

    case manual_input_step do
      %{config: %{"trigger_data" => raw_json}} when is_binary(raw_json) ->
        case Jason.decode(raw_json) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      %{config: %{"trigger_data" => data}} when is_map(data) ->
        data

      _ ->
        %{}
    end
  end

  defp build_preview_draft(draft, %EditorState{} = editor_state) do
    disabled_steps = editor_state.disabled_steps || MapSet.new()

    steps =
      Enum.reject(draft.steps, fn step ->
        MapSet.member?(disabled_steps, step.id)
      end)

    step_ids = MapSet.new(Enum.map(steps, & &1.id))

    connections =
      Enum.filter(draft.connections, fn conn ->
        MapSet.member?(step_ids, conn.source_step_id) and
          MapSet.member?(step_ids, conn.target_step_id)
      end)

    %{draft | steps: steps, connections: connections}
  end

  defp build_initial_step_executions(execution_id, steps) do
    now = DateTime.utc_now()

    Enum.map(steps, fn step ->
      %{
        id: "#{execution_id}:#{step.id}",
        execution_id: execution_id,
        step_id: step.id,
        step_type_id: step.type_id,
        status: :pending,
        attempt: 1,
        inserted_at: now
      }
    end)
  end

  defp normalize_execution_metadata(nil), do: %{}

  defp normalize_execution_metadata(%{__struct__: _} = metadata) do
    Map.from_struct(metadata)
  end

  defp normalize_execution_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_execution_metadata(_metadata), do: %{}

  defp subscribe_execution(scope, execution_id) do
    case ExecutionPubSub.subscribe_execution(scope, execution_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp unsubscribe_execution(socket) do
    case socket.assigns.execution_id do
      nil ->
        socket

      execution_id ->
        ExecutionPubSub.unsubscribe_execution(execution_id)

        socket
        |> assign(:execution_id, nil)
        |> assign(:execution, nil)
        |> assign(:step_executions, [])
    end
  end

  defp start_execution_process(execution_id) do
    case ExecutionSupervisor.start_execution(execution_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_stop_execution_process(execution_id) do
    case ExecutionSupervisor.get_execution_pid(execution_id) do
      {:ok, pid} ->
        Process.exit(pid, :shutdown)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp refresh_execution_from_event(socket, %{execution_id: execution_id}) do
    case Executions.get_execution(socket.assigns.current_scope, execution_id) do
      {:ok, execution} -> assign(socket, :execution, execution)
      {:error, _} -> socket
    end
  end

  defp update_execution_assign(socket, %Execution{id: execution_id} = execution) do
    if execution_id == socket.assigns.execution_id do
      assign(socket, :execution, execution)
    else
      socket
    end
  end

  defp update_step_executions(socket, event, payload) do
    execution_id = socket.assigns.execution_id
    step_execution = normalize_step_payload(payload, execution_id, event)

    if step_execution do
      step_executions = upsert_step_execution(socket.assigns.step_executions, step_execution)
      assign(socket, :step_executions, step_executions)
    else
      socket
    end
  end

  defp normalize_step_payload(payload, execution_id, event) do
    step_id = fetch_payload_value(payload, :step_id)
    payload_execution_id = fetch_payload_value(payload, :execution_id) || execution_id

    if step_id && payload_execution_id && payload_execution_id == execution_id do
      %{
        id: fetch_payload_value(payload, :id) || "#{payload_execution_id}:#{step_id}",
        execution_id: payload_execution_id,
        step_id: step_id,
        step_type_id: fetch_payload_value(payload, :step_type_id),
        status: fetch_payload_value(payload, :status) || default_step_status(event),
        input_data: fetch_payload_value(payload, :input_data),
        output_data: fetch_payload_value(payload, :output_data),
        output_item_count: fetch_payload_value(payload, :output_item_count),
        error: fetch_payload_value(payload, :error),
        attempt: fetch_payload_value(payload, :attempt) || 1,
        queued_at: fetch_payload_value(payload, :queued_at),
        started_at: fetch_payload_value(payload, :started_at),
        completed_at: fetch_payload_value(payload, :completed_at),
        duration_us: fetch_payload_value(payload, :duration_us),
        metadata: fetch_payload_value(payload, :metadata)
      }
    end
  end

  defp fetch_payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp fetch_payload_value(_payload, _key), do: nil

  defp default_step_status(:step_started), do: :running
  defp default_step_status(:step_failed), do: :failed
  defp default_step_status(:step_completed), do: :completed
  defp default_step_status(:step_skipped), do: :skipped
  defp default_step_status(_event), do: :pending

  defp upsert_step_execution(step_executions, step_execution) do
    step_id = Map.get(step_execution, :step_id)

    case Enum.find_index(step_executions, fn existing ->
           Map.get(existing, :step_id) == step_id
         end) do
      nil ->
        step_executions ++ [step_execution]

      index ->
        existing = Enum.at(step_executions, index)

        # Merge but preserve existing values if new ones are nil
        updated =
          Enum.reduce(step_execution, existing, fn {k, v}, acc ->
            if is_nil(v) do
              acc
            else
              Map.put(acc, k, v)
            end
          end)

        List.replace_at(step_executions, index, updated)
    end
  end

  defp format_test_webhook_error(:webhook_not_found), do: "webhook trigger not found"
  defp format_test_webhook_error(:not_found), do: "edit session not running"
  defp format_test_webhook_error(reason), do: inspect(reason)

  defp format_execution_error(:access_denied), do: "access denied"
  defp format_execution_error(:workflow_not_found), do: "workflow not found"
  defp format_execution_error(:workflow_not_published), do: "workflow not published"
  defp format_execution_error(:unauthorized), do: "access denied"
  defp format_execution_error(:not_found), do: "execution not found"

  defp format_execution_error(%Ecto.Changeset{} = changeset) do
    error =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> inspect()

    "invalid execution: #{error}"
  end

  defp format_execution_error(reason), do: inspect(reason)

  defp handle_presence_diff(socket, _diff) do
    # Fetch latest full presence list
    presences = format_presences(Presence.list_users(socket.assigns.workflow.id))
    # todo: should we assign and push_event?
    socket =
      socket
      |> assign(:presences, presences)
      |> push_event("presence_update", %{presences: presences})

    {:noreply, socket}
  end

  defp format_presences(presence_list) do
    real_presences =
      presence_list
      |> Enum.map(fn {user_id, %{metas: metas}} ->
        # Take the most recent meta (first one)
        meta = List.first(metas) || %{}

        %{
          user: %{
            id: user_id,
            name: get_in(meta, [:user, :name]),
            email: get_in(meta, [:user, :email])
          },
          cursor: meta[:cursor],
          dragging_steps: meta[:dragging_steps],
          selected_steps: meta[:selected_steps] || [],
          focused_step: meta[:focused_step]
        }
      end)

    # Add mock cursors for testing (always add them to see the appearance)
    mock_presences =
      if Mix.env() == :dev do
        [
          %{
            user: %{id: "mock-1", name: "Alice", email: "alice@example.com"},
            cursor: %{x: 200, y: 100},
            selected_steps: [],
            focused_step: nil
          },
          %{
            user: %{id: "mock-2", name: "Bob", email: "bob@example.com"},
            cursor: %{x: 350, y: 250},
            selected_steps: [],
            focused_step: nil
          },
          %{
            user: %{id: "mock-3", name: "Charlie", email: "charlie@example.com"},
            cursor: %{x: 500, y: 180},
            selected_steps: [],
            focused_step: nil
          },
          %{
            user: %{id: "mock-4", name: "Diana", email: "diana@example.com"},
            cursor: %{x: 650, y: 300},
            selected_steps: [],
            focused_step: nil
          }
        ]
      else
        []
      end

    real_presences ++ mock_presences
  end

  defp deserialize_editor_state(nil, workflow_id) do
    %EditorState{workflow_id: workflow_id}
  end

  defp deserialize_editor_state(state, workflow_id) when is_map(state) do
    %EditorState{
      workflow_id: workflow_id,
      pinned_outputs: state[:pinned_outputs] || state["pinned_outputs"] || %{},
      disabled_steps: MapSet.new(state[:disabled_steps] || state["disabled_steps"] || []),
      disabled_mode: state[:disabled_mode] || state["disabled_mode"] || %{},
      step_locks: state[:step_locks] || state["step_locks"] || %{},
      webhook_test: state[:webhook_test] || state["webhook_test"]
    }
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(%{message: message}), do: message
  defp format_error_message(%{"message" => message}), do: message
  defp format_error_message(error), do: inspect(error)
end
