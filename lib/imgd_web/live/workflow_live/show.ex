defmodule ImgdWeb.WorkflowLive.Show do
  @moduledoc """
  LiveView for showing a workflow.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  import ImgdWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    try do
      workflow = Workflows.get_workflow!(scope, id)

      socket =
        socket
        |> assign(:page_title, workflow.name)
        |> assign(:workflow, workflow)

      {:ok, socket}
    rescue
      _ ->
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <div class="flex items-center gap-3">
                <.link navigate={~p"/workflows"} class="btn btn-ghost btn-sm">
                  <.icon name="hero-arrow-left" class="size-4" />
                  <span>Back to Workflows</span>
                </.link>
              </div>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                  {@workflow.name}
                </h1>
                <span class="badge badge-ghost badge-xs">v{@workflow.version}</span>
                <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                  {status_label(@workflow.status)}
                </span>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                {@workflow.description || "No description provided."}
              </p>
              <div class="flex items-center gap-4 text-xs text-base-content/60">
                <div class="flex items-center gap-1">
                  <.icon name="hero-clock" class="size-4" />
                  <span>Updated {formatted_timestamp(@workflow.updated_at)}</span>
                </div>
                <div class="flex items-center gap-1">
                  <.icon name="hero-calendar" class="size-4" />
                  <span>Created {formatted_timestamp(@workflow.inserted_at)}</span>
                </div>
                <div class="text-[11px] font-mono uppercase tracking-wide">
                  {short_id(@workflow.id)}
                </div>
              </div>
            </div>

            <div class="flex gap-3">
              <button class="btn btn-outline btn-sm gap-2">
                <.icon name="hero-play" class="size-4" />
                <span>Run Workflow</span>
              </button>
              <button class="btn btn-primary btn-sm gap-2">
                <.icon name="hero-pencil-square" class="size-4" />
                <span>Edit</span>
              </button>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <div class="card relative overflow-hidden transition-all duration-300 border border-base-300 rounded-2xl shadow-sm ring-1 ring-base-300/70 bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4">Workflow Details</h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Trigger</label>
                  <div class="flex items-center gap-2 mt-1">
                    <.icon name="hero-bolt" class="size-4 opacity-70" />
                    <span class="text-sm">{trigger_label(@workflow)}</span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Status</label>
                  <div class="mt-1">
                    <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                      {status_label(@workflow.status)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Version</label>
                  <div class="mt-1">
                    <span class="text-sm">v{@workflow.version}</span>
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Created</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.inserted_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Last Updated</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.updated_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Workflow ID</label>
                  <div class="mt-1">
                    <code class="text-xs bg-base-200 px-2 py-1 rounded">{@workflow.id}</code>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
