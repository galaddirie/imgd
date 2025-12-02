defmodule ImgdWeb.WorkflowLive.Index do
  @moduledoc """
  LiveView for browsing workflows.

  Presents an index of workflows.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  import ImgdWeb.Formatters

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    workflows =
      scope
      |> Workflows.list_workflows()
      |> sort_workflows()

    socket =
      socket
      |> assign(:page_title, "Workflows")
      |> assign(:workflows_empty?, workflows == [])
      |> stream(:workflows, workflows, dom_id: &"workflow-#{&1.id}")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-muted">Automation</p>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">Workflows</h1>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                Design, publish, and monitor the automations scoped to {@current_scope.user.email}.
                Drafts stay private until you publish them.
              </p>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <div class="card relative overflow-hidden transition-all duration-300 border border-base-300 rounded-2xl shadow-sm ring-1 ring-base-300/70 bg-base-100 p-3">
            <div class="flex items-center justify-between px-4 text-sm"></div>
            <.data_table
              id="workflows"
              rows={@streams.workflows}
              rows_empty?={@workflows_empty?}
              tbody_class="divide-y divide-base-200"
            >
              <:col :let={workflow} label="Workflow">
                <div class="space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-base-content">{workflow.name}</p>
                    <span class="badge badge-ghost badge-xs">v{workflow.version}</span>
                  </div>
                  <p class="text-xs leading-relaxed text-base-content/70">
                    {workflow.description || "Add context so collaborators know when to use it."}
                  </p>
                  <p class="text-[11px] font-mono uppercase tracking-wide text-base-content/50">
                    {short_id(workflow.id)}
                  </p>
                </div>
              </:col>

              <:col :let={workflow} label="Trigger" width="16%">
                <div class="flex items-center gap-2 text-xs font-medium text-base-content/80">
                  <.icon name="hero-bolt" class="size-4 opacity-70" />
                  <span>{trigger_label(workflow)}</span>
                </div>
              </:col>

              <:col :let={workflow} label="Status" width="14%" align="center">
                <span
                  class={["badge badge-sm", status_badge_class(workflow.status)]}
                  data-role="status"
                  data-status={workflow.status}
                >
                  {status_label(workflow.status)}
                </span>
              </:col>

              <:col :let={workflow} label="Updated" width="18%">
                <div class="flex items-center gap-2 text-xs text-base-content/70">
                  <.icon name="hero-clock" class="size-4 opacity-70" />
                  <span>{formatted_timestamp(workflow.updated_at)}</span>
                </div>
              </:col>

              <:col :let={workflow} label="Created" width="18%">
                <div class="text-xs text-base-content/60">
                  {formatted_timestamp(workflow.inserted_at)}
                </div>
              </:col>

              <:empty_state>
                <div class="flex flex-col items-center justify-center gap-3 py-10 text-base-content/70">
                  <div class="rounded-full bg-base-200 p-3">
                    <.icon name="hero-rocket-launch" class="size-6" />
                  </div>
                  <div class="space-y-1 text-center">
                    <p class="text-sm font-semibold text-base-content">No workflows yet</p>
                    <p class="text-xs">Create one above to get started.</p>
                  </div>
                </div>
              </:empty_state>
            </.data_table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp sort_workflows(workflows) do
    Enum.sort_by(
      workflows,
      fn workflow ->
        workflow.updated_at || workflow.inserted_at
      end,
      {:desc, DateTime}
    )
  end
end
