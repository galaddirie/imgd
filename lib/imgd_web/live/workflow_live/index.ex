defmodule ImgdWeb.WorkflowLive.Index do
  @moduledoc """
  LiveView for the workflows landing page.
  """
  use ImgdWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Workflows")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div id="workflows-page-header" class={["flex", "flex-col", "gap-4", "pb-8"]}>
          <div class={["flex", "items-center", "justify-between", "gap-6"]}>
            <div class={["flex", "flex-col", "gap-2"]}>
              <p class={["text-sm", "font-semibold", "uppercase", "tracking-widest", "text-zinc-400"]}>
                Automations
              </p>
              <h1 class={["text-3xl", "font-semibold", "tracking-tight", "text-base-content"]}>
                {@page_title}
              </h1>
              <p class={["max-w-2xl", "text-base", "text-base-content/70"]}>
                Design, run, and monitor workflows with live status, test runs, and rich previews.
              </p>
            </div>
            <button
              id="workflows-new-button"
              type="button"
              class={[
                "btn",
                "btn-primary",
                "btn-sm",
                "gap-2",
                "transition",
                "duration-200",
                "hover:translate-y-[-1px]"
              ]}
              disabled
            >
              <.icon name="hero-plus" class="size-4" /> New workflow
            </button>
          </div>
        </div>
      </:page_header>

      <section
        id="workflows-empty-state"
        class={[
          "rounded-3xl",
          "border",
          "border-dashed",
          "border-base-300",
          "bg-base-100",
          "p-10",
          "text-center"
        ]}
      >
        <div class={["mx-auto", "flex", "max-w-xl", "flex-col", "items-center", "gap-4"]}>
          <div class={[
            "flex",
            "h-12",
            "w-12",
            "items-center",
            "justify-center",
            "rounded-full",
            "bg-primary/10",
            "text-primary"
          ]}>
            <.icon name="hero-squares-2x2" class="size-6" />
          </div>
          <h2 class={["text-xl", "font-semibold", "text-base-content"]}>
            No workflows yet
          </h2>
          <p class={["text-sm", "text-base-content/70"]}>
            Create your first automation to start orchestrating tasks and integrations.
          </p>
          <div class={["flex", "flex-wrap", "justify-center", "gap-3"]}>
            <button
              id="workflows-empty-primary"
              type="button"
              class={["btn", "btn-primary", "btn-sm", "gap-2"]}
              disabled
            >
              <.icon name="hero-sparkles" class="size-4" /> Start from a template
            </button>
            <button
              id="workflows-empty-secondary"
              type="button"
              class={["btn", "btn-ghost", "btn-sm", "gap-2"]}
              disabled
            >
              <.icon name="hero-play" class="size-4" /> Run a sample
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
