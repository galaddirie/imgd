defmodule ImgdWeb.FlowLive do
  @moduledoc """
  LiveView demo for SvelteFlow via LiveSvelte.
  """
  use ImgdWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    nodes = [
      %{id: "brief", position: %{x: 100, y: 100}, data: %{label: "Brief"}},
      %{id: "design", position: %{x: 300, y: 100}, data: %{label: "Design"}},
      %{id: "ship", position: %{x: 500, y: 100}, data: %{label: "Ship"}}
    ]

    edges = [
      %{id: "brief-design", source: "brief", target: "design"},
      %{id: "design-ship", source: "design", target: "ship"}
    ]

    {:ok,
     socket
     |> assign(page_title: "Svelte Flow")
     |> assign(nodes: nodes, edges: edges)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/svelte-flow"}>
      <:page_header>
        <div class={["w-full", "space-y-6"]}>
          <div class={[
            "flex",
            "flex-col",
            "gap-4",
            "lg:flex-row",
            "lg:items-end",
            "lg:justify-between"
          ]}>
            <div class={["space-y-3"]}>
              <p class={["text-xs", "font-semibold", "uppercase", "tracking-[0.3em]", "text-muted"]}>
                SvelteFlow
              </p>
              <h1 class={["text-3xl", "font-semibold", "tracking-tight", "text-base-content"]}>
                Interactive flow canvas
              </h1>
              <p class={["max-w-2xl", "text-sm", "text-muted"]}>
                Drag nodes, pan, and zoom the canvas. The LiveView owns the data,
                Svelte handles the UI interactions.
              </p>
            </div>
            <div class={["flex", "flex-wrap", "gap-2"]}>
              <div class={[
                "rounded-full",
                "border",
                "border-base-200",
                "bg-base-100",
                "px-3",
                "py-1",
                "text-xs",
                "font-medium",
                "text-base-content/70"
              ]}>
                drag nodes
              </div>
              <div class={[
                "rounded-full",
                "border",
                "border-base-200",
                "bg-base-100",
                "px-3",
                "py-1",
                "text-xs",
                "font-medium",
                "text-base-content/70"
              ]}>
                scroll to zoom
              </div>
              <div class={[
                "rounded-full",
                "border",
                "border-base-200",
                "bg-base-100",
                "px-3",
                "py-1",
                "text-xs",
                "font-medium",
                "text-base-content/70"
              ]}>
                drag to pan
              </div>
            </div>
          </div>
        </div>
      </:page_header>

      <section class={["grid", "gap-6"]}>
        <div
          id="svelte-flow-card"
          class={[
            "rounded-3xl",
            "border",
            "border-base-200",
            "bg-base-100/70",
            "p-4",
            "shadow-sm"
          ]}
        >
          <div class={["flex", "items-center", "justify-between", "gap-4", "px-2", "pb-4"]}>
            <div class={["space-y-1"]}>
              <p class={["text-sm", "font-semibold", "text-base-content"]}>Live canvas</p>
              <p class={["text-xs", "text-muted"]}>
                Mini map and controls match the default SvelteFlow theme.
              </p>
            </div>
            <div class={[
              "rounded-full",
              "border",
              "border-base-200",
              "bg-base-100",
              "px-3",
              "py-1",
              "text-xs",
              "font-medium",
              "text-base-content/70"
            ]}>
              LiveSvelte
            </div>
          </div>

          <div
            id="svelte-flow-canvas"
            class={[
              "h-[60vh]",
              "min-h-[28rem]",
              "w-full",
              "rounded-2xl",
              "border",
              "border-base-200",
              "bg-base-100"
            ]}
          >
            <.svelte
              name="FlowDemo"
              socket={@socket}
              props={%{nodes: @nodes, edges: @edges}}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
