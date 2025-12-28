defmodule ImgdWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for designing and editing workflows with real-time collaboration.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Steps.Registry, as: StepRegistry
  alias Imgd.Collaboration.EditorState
  alias Imgd.Collaboration.EditSession.{Server, Presence, PubSub, Operations}
  alias Ecto.UUID

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    case Workflows.get_workflow_with_draft(id, scope) do
      {:ok, workflow} ->
        case PubSub.authorize_edit(scope, workflow.id) do
          :ok ->
            step_types = StepRegistry.all()

            socket =
              socket
              |> assign(:page_title, "Editing #{workflow.name}")
              |> assign(:workflow, workflow)
              |> assign(:step_types, step_types)
              |> assign(:editor_state, %EditorState{workflow_id: workflow.id})
              |> assign(:presences, [])
              |> assign(:current_user_id, user.id)

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

    socket
    |> assign(:editor_state, editor_state)
    |> assign(:presences, presences)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen overflow-hidden bg-base-200">
      <.vue
        v-component="WorkflowEditor"
        v-ssr={false}
        v-socket={@socket}
        workflow={@workflow}
        stepTypes={@step_types}
        editorState={@editor_state}
        presences={@presences}
        currentUserId={@current_user_id}
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
      />
    </div>
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

    step = %{
      id: UUID.generate(),
      type_id: type_id,
      name: step_type_name,
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
  def handle_event("mouse_move", %{"x" => x, "y" => y}, socket) do
    Presence.update_cursor(
      socket.assigns.workflow.id,
      socket.assigns.current_user_id,
      %{x: x, y: y}
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
    Server.persist(socket.assigns.workflow.id)
    {:noreply, put_flash(socket, :info, "Workflow draft saved")}
  end

  @impl true
  def handle_event("run_test", _params, socket) do
    # TODO: Implement test execution
    {:noreply, put_flash(socket, :info, "Test execution started")}
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

      {:error, _reason} ->
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
    {:noreply, assign(socket, :editor_state, new_editor_state)}
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
    socket =
      socket
      |> assign(:workflow, %{socket.assigns.workflow | draft: state.draft})
      |> assign(
        :editor_state,
        deserialize_editor_state(state.editor_state, socket.assigns.workflow.id)
      )

    {:noreply, socket}
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

  defp handle_presence_diff(socket, _diff) do
    # Refresh the full presence list on any change
    # This is simpler and more reliable than tracking diffs
    presences = format_presences(Presence.list_users(socket.assigns.workflow.id))
    {:noreply, assign(socket, :presences, presences)}
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
      step_locks: state[:step_locks] || state["step_locks"] || %{}
    }
  end
end
