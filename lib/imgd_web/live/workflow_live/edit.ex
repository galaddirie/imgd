defmodule ImgdWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for designing and editing workflows.
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

    # Ensure collaboration server is running
    {:ok, _pid} = Imgd.Collaboration.EditSession.Supervisor.ensure_session(id)

    case Workflows.get_workflow_with_draft(id, scope) do
      {:ok, workflow} ->
        # Check edit permissions (but don't subscribe yet - that happens when connected)
        case PubSub.authorize_edit(scope, workflow.id) do
          :ok ->
            step_types = StepRegistry.all()

            # Subscribe to PubSub and track presence ONLY when WebSocket is connected
            # This is critical: the initial HTTP mount creates a temporary process,
            # but the WebSocket mount creates the persistent process that needs to receive updates
            {editor_state, presences} =
              if connected?(socket) do
                # Subscribe to collaboration events
                :ok = Phoenix.PubSub.subscribe(Imgd.PubSub, PubSub.session_topic(workflow.id))
                :ok = Phoenix.PubSub.subscribe(Imgd.PubSub, PubSub.presence_topic(workflow.id))

                # Track current user
                {:ok, _} = Presence.track_user(workflow.id, user, socket)

                # Get initial editor state from session server
                es =
                  case Server.get_editor_state(workflow.id) do
                    {:ok, state} -> state
                    _ -> %EditorState{workflow_id: workflow.id}
                  end

                # Get initial presences
                p = format_presences(Presence.list_users(workflow.id))

                {es, p}
              else
                # Not connected yet - use defaults
                {%EditorState{workflow_id: workflow.id}, []}
              end

            socket =
              socket
              |> assign(:page_title, "Editing #{workflow.name}")
              |> assign(:workflow, workflow)
              |> assign(:step_types, step_types)
              |> assign(:editor_state, editor_state)
              |> assign(:presences, presences)

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen overflow-hidden bg-base-200">
      <.vue
        v-component="WorkflowEditor"
        v-ssr={false}
        workflow={@workflow}
        stepTypes={@step_types}
        editorState={@editor_state}
        presences={@presences}
        currentUserId={@current_scope.user.id}
        v-on:add_step={handle_add_step()}
        v-on:move_step={handle_move_step()}
        v-on:update_step={handle_update_step()}
        v-on:remove_step={handle_remove_step()}
        v-on:add_connection={handle_add_connection()}
        v-on:remove_connection={handle_remove_connection()}
        v-on:save_workflow={handle_save_workflow()}
        v-on:mouse_move={JS.push("mouse_move")}
        v-on:selection_changed={JS.push("selection_changed")}
      />
    </div>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  defp handle_add_step, do: JS.push("add_step")
  defp handle_move_step, do: JS.push("move_step")
  defp handle_update_step, do: JS.push("update_step")
  defp handle_remove_step, do: JS.push("remove_step")
  defp handle_add_connection, do: JS.push("add_connection")
  defp handle_remove_connection, do: JS.push("remove_connection")
  defp handle_save_workflow, do: JS.push("save_workflow")

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

    operation = %{
      id: UUID.generate(),
      type: :add_step,
      payload: %{step: step},
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("move_step", %{"step_id" => step_id, "position" => pos}, socket) do
    operation = %{
      id: UUID.generate(),
      type: :update_step_position,
      payload: %{step_id: step_id, position: pos},
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_step", %{"step_id" => step_id, "changes" => changes}, socket) do
    operation = %{
      id: UUID.generate(),
      type: :update_step_config,
      payload: %{step_id: step_id, changes: changes},
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_step", %{"step_id" => step_id}, socket) do
    operation = %{
      id: UUID.generate(),
      type: :remove_step,
      payload: %{step_id: step_id},
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_connection", params, socket) do
    operation = %{
      id: UUID.generate(),
      type: :add_connection,
      payload: params,
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_connection", %{"connection_id" => id}, socket) do
    operation = %{
      id: UUID.generate(),
      type: :remove_connection,
      payload: %{connection_id: id},
      user_id: socket.assigns.current_scope.user.id,
      client_seq: nil
    }

    Server.apply_operation(socket.assigns.workflow.id, operation)
    {:noreply, socket}
  end

  @impl true
  def handle_event("mouse_move", pos, socket) do
    Presence.update_cursor(
      socket.assigns.workflow.id,
      socket.assigns.current_scope.user.id,
      pos
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("selection_changed", %{"step_ids" => step_ids}, socket) do
    Presence.update_selection(
      socket.assigns.workflow.id,
      socket.assigns.current_scope.user.id,
      step_ids
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_workflow", _params, socket) do
    Server.persist(socket.assigns.workflow.id)
    {:noreply, put_flash(socket, :info, "Workflow draft saved")}
  end

  # ============================================================================
  # Info Handlers (PubSub)
  # ============================================================================

  @impl true
  def handle_info({:operation_applied, operation}, socket) do
    # Apply operation locally to avoid race condition with async persistence
    case Operations.apply(socket.assigns.workflow.draft, operation) do
      {:ok, new_draft} ->
        updated_workflow = %{socket.assigns.workflow | draft: new_draft}
        {:noreply, assign(socket, :workflow, updated_workflow)}

      {:error, _reason} ->
        # If local application fails, fall back to DB fetch (though it might be stale)
        {:ok, workflow} =
          Workflows.get_workflow_with_draft(
            socket.assigns.workflow.id,
            socket.assigns.current_scope
          )

        {:noreply, assign(socket, :workflow, workflow)}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: _payload}, socket) do
    presences = format_presences(Presence.list_users(socket.assigns.workflow.id))
    {:noreply, assign(socket, :presences, presences)}
  end

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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_presences(presence_list) do
    presence_list
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      meta = List.first(metas)

      %{
        user: %{
          id: user_id,
          name: meta.user.name,
          email: meta.user.email
        },
        cursor: meta[:cursor],
        selected_steps: meta[:selected_steps] || [],
        focused_step_id: meta[:focused_step]
      }
    end)
  end
end
