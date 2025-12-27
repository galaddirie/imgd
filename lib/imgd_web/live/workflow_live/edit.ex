defmodule ImgdWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for designing and editing workflows.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Steps.Registry, as: StepRegistry
  alias Imgd.Collaboration.EditorState

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Workflows.get_workflow_with_draft(id, scope) do
      {:ok, workflow} ->
        step_types = StepRegistry.all()

        socket =
          socket
          |> assign(:page_title, "Editing #{workflow.name}")
          |> assign(:workflow, workflow)
          |> assign(:step_types, step_types)
          # Placeholder for collaboration/session state
          |> assign(:editor_state, %EditorState{workflow_id: workflow.id})
          |> assign(:presences, [])

        {:ok, socket, layout: false}

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
        workflow={@workflow}
        stepTypes={@step_types}
        editorState={@editor_state}
        presences={@presences}
        v-on:add_step={handle_add_step()}
        v-on:move_step={handle_move_step()}
        v-on:update_step={handle_update_step()}
        v-on:remove_step={handle_remove_step()}
        v-on:add_connection={handle_add_connection()}
        v-on:remove_connection={handle_remove_connection()}
        v-on:save_workflow={handle_save_workflow()}
      />
    </div>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  defp handle_add_step do
    JS.push("add_step")
  end

  defp handle_move_step do
    JS.push("move_step")
  end

  defp handle_update_step do
    JS.push("update_step")
  end

  defp handle_remove_step do
    JS.push("remove_step")
  end

  defp handle_add_connection do
    JS.push("add_connection")
  end

  defp handle_remove_connection do
    JS.push("remove_connection")
  end

  defp handle_save_workflow do
    JS.push("save_workflow")
  end

  @impl true
  def handle_event("add_step", %{"type_id" => _type_id, "position" => _pos}, socket) do
    # Implementation for adding step to draft
    {:noreply, socket}
  end

  @impl true
  def handle_event("move_step", %{"step_id" => _step_id, "position" => _pos}, socket) do
    # Implementation for moving step in draft
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_step", %{"step_id" => _step_id, "changes" => _changes}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_step", %{"step_id" => _step_id}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "add_connection",
        %{"source_step_id" => _s, "target_step_id" => _t} = _params,
        socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_connection", %{"connection_id" => _id}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_workflow", _params, socket) do
    {:noreply, socket}
  end
end
