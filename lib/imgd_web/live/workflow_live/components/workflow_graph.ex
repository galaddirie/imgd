defmodule ImgdWeb.WorkflowLive.Components.WorkflowGraph do
  @moduledoc """
  A LiveComponent that renders a static visualization of a Runic workflow graph.

  Uses SVG to render nodes and edges in a simple left-to-right layout,
  with a focus on readability and visual grouping.
  """
  use Phoenix.LiveComponent

  alias Imgd.Workflows.GraphExtractor

  @impl true
  def mount(socket) do
    {:ok, assign(socket, graph_data: nil, error: nil)}
  end

  @impl true
  def update(%{workflow: workflow} = assigns, socket) do
    graph_result =
      case GraphExtractor.extract(workflow) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end

    socket =
      socket
      |> assign(assigns)
      |> assign_graph_result(graph_result)

    {:ok, socket}
  end

  defp assign_graph_result(socket, {:ok, data}) do
    assign(socket, graph_data: data, error: nil)
  end

  defp assign_graph_result(socket, {:error, reason}) do
    assign(socket, graph_data: nil, error: reason)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workflow-graph-container rounded-xl border border-base-300 bg-base-200/60 p-3">
      <%= if @error do %>
        <div class="flex items-center justify-center h-64 rounded-lg bg-base-200">
          <div class="text-center text-base-content/60">
            <svg class="size-8 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
              />
            </svg>
            <p class="text-sm">Unable to render workflow graph</p>
            <p class="text-xs mt-1 font-mono opacity-80">{inspect(@error)}</p>
          </div>
        </div>
      <% else %>
        <%= if @graph_data && length(@graph_data.nodes) > 0 do %>
          <div class="relative w-full overflow-x-auto">
            <svg
              class="w-full rounded-lg shadow-sm"
              viewBox={compute_viewbox(@graph_data)}
              preserveAspectRatio="xMidYMid meet"
              style="min-height: 240px; max-height: 420px;"
            >
              <defs>
                <%!-- Soft grid background --%>
                <pattern
                  id="workflow-grid"
                  width="32"
                  height="32"
                  patternUnits="userSpaceOnUse"
                >
                  <path
                    d="M 32 0 L 0 0 0 32"
                    fill="none"
                    stroke="#e5e7eb"
                    stroke-width="0.5"
                  />
                </pattern>

                <%!-- Node shadow --%>
                <filter id="node-shadow" x="-20%" y="-20%" width="140%" height="140%">
                  <feDropShadow
                    dx="0"
                    dy="2"
                    stdDeviation="2"
                    flood-color="#000000"
                    flood-opacity="0.12"
                  />
                </filter>

                <%!-- Arrowhead for edges --%>
                <marker
                  id="arrowhead"
                  markerWidth="8"
                  markerHeight="8"
                  refX="5"
                  refY="4"
                  orient="auto"
                >
                  <polygon points="0 0, 6 4, 0 8" fill="#cbd5f5" />
                </marker>
              </defs>

              <%!-- Background grid --%>
              <rect
                x="0"
                y="0"
                width="100%"
                height="100%"
                fill="url(#workflow-grid)"
                rx="12"
                ry="12"
              />

              <%!-- Render edges first (behind nodes) --%>
              <%= for edge <- @graph_data.edges do %>
                <.edge edge={edge} layout={@graph_data.layout} />
              <% end %>

              <%!-- Render nodes --%>
              <%= for node <- @graph_data.nodes do %>
                <.graph_node node={node} layout={@graph_data.layout} />
              <% end %>
            </svg>
          </div>

          <%!-- Legend --%>
          <div class="mt-3 flex flex-wrap items-center gap-2 text-[11px] text-base-content/60">
            <span class="mr-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/70">
              Legend
            </span>
            <.legend_chip label="Step" type={:step} />
            <.legend_chip label="Rule" type={:rule} />
            <.legend_chip label="Accumulator" type={:accumulator} />
            <.legend_chip label="State machine" type={:state_machine} />
          </div>
        <% else %>
          <div class="flex items-center justify-center h-64 rounded-lg bg-base-200">
            <div class="text-center text-base-content/60">
              <svg class="size-8 mx-auto mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
                />
              </svg>
              <p class="text-sm">No workflow nodes defined</p>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  ## NODE RENDERING

  defp graph_node(assigns) do
    {x, y, w, h} = Map.get(assigns.layout, assigns.node.id, {0, 0, 160, 72})

    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:w, w)
      |> assign(:h, h)
      |> assign(:colors, node_colors(assigns.node.type))

    ~H"""
    <g class="workflow-node" data-node-id={@node.id}>
      <%!-- Node card background with header strip --%>
      <rect
        x={@x}
        y={@y}
        width={@w}
        height={@h}
        rx="10"
        ry="10"
        fill={@colors.bg}
        stroke="#e5e7eb"
        stroke-width="1.2"
        filter="url(#node-shadow)"
      />

      <%!-- Icon badge --%>
      <rect
        x={@x + 10}
        y={@y + 14}
        width="26"
        height="26"
        rx="8"
        fill={@colors.badge}
      />
      <text
        x={@x + 23}
        y={@y + 31}
        text-anchor="middle"
        font-size="13"
        font-weight="600"
        fill={@colors.badge_text}
      >
        {node_icon(@node.type)}
      </text>

      <%!-- Node name --%>
      <text
        x={@x + 46}
        y={@y + 24}
        font-size="13"
        font-weight="600"
        fill={@colors.text}
      >
        {truncate_name(@node.name, 20)}
      </text>

      <%!-- Node type label --%>
      <text
        x={@x + 46}
        y={@y + 42}
        font-size="11"
        fill={@colors.subtext}
      >
        {node_type_label(@node.type)}
      </text>

      <%!-- Optional ID / debug info in tiny text --%>
      <text
        x={@x + 12}
        y={@y + @h - 10}
        font-size="9"
        fill={@colors.subtext}
        opacity="0.7"
      >
        {truncate_name(to_string(@node.id), 18)}
      </text>
    </g>
    """
  end

  ## EDGE RENDERING

  defp edge(assigns) do
    from_pos = Map.get(assigns.layout, assigns.edge.from)
    to_pos = Map.get(assigns.layout, assigns.edge.to)

    if from_pos && to_pos do
      {from_x, from_y, from_w, from_h} = from_pos
      {to_x, to_y, _to_w, to_h} = to_pos

      # Connection points (right side of source, left side of target)
      start_x = from_x + from_w
      start_y = from_y + from_h / 2
      end_x = to_x
      end_y = to_y + to_h / 2

      # Smooth S-curve instead of tight bend
      dx = max(end_x - start_x, 40)
      c1_x = start_x + min(dx * 0.35, 60)
      c2_x = end_x - min(dx * 0.35, 60)

      path = "M#{start_x},#{start_y} C#{c1_x},#{start_y} #{c2_x},#{end_y} #{end_x},#{end_y}"

      assigns =
        assigns
        |> assign(:path, path)

      ~H"""
      <path
        d={@path}
        fill="none"
        stroke="#cbd5f5"
        stroke-width="1.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-opacity="0.95"
        marker-end="url(#arrowhead)"
      />
      """
    else
      ~H"""
      """
    end
  end

  ## VIEWBOX

  defp compute_viewbox(%{layout: layout}) when map_size(layout) == 0 do
    "0 0 400 200"
  end

  defp compute_viewbox(%{layout: layout}) do
    positions = Map.values(layout)

    max_x = positions |> Enum.map(fn {x, _y, w, _h} -> x + w end) |> Enum.max(fn -> 400 end)
    max_y = positions |> Enum.map(fn {_x, y, _w, h} -> y + h end) |> Enum.max(fn -> 200 end)

    "0 0 #{max_x + 80} #{max_y + 80}"
  end

  ## STYLES / COLORS

  defp node_colors(:step) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      accent: "#dbeafe",
      badge: "#2563eb",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp node_colors(:rule) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      accent: "#d1fae5",
      badge: "#059669",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp node_colors(:accumulator) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      accent: "#fef3c7",
      badge: "#d97706",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp node_colors(:state_machine) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      accent: "#ede9fe",
      badge: "#7c3aed",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp node_colors(_) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      accent: "#e5e7eb",
      badge: "#6b7280",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  ## LEGEND

  defp legend_chip(assigns) do
    assigns = assign(assigns, :colors, node_colors(assigns.type))

    ~H"""
    <div class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-100 px-2 py-0.5">
      <span
        class="inline-block size-2.5 rounded-full"
        style={"background-color: #{@colors.badge};"}
      >
      </span>
      <span>{@label}</span>
    </div>
    """
  end

  ## LABEL HELPERS

  defp node_icon(:step), do: "ƒ"
  defp node_icon(:rule), do: "?"
  defp node_icon(:accumulator), do: "Σ"
  defp node_icon(:state_machine), do: "◉"
  defp node_icon(_), do: "•"

  defp node_type_label(:step), do: "Step"
  defp node_type_label(:rule), do: "Rule"
  defp node_type_label(:accumulator), do: "Accumulator"
  defp node_type_label(:state_machine), do: "State Machine"
  defp node_type_label(type), do: to_string(type)

  defp truncate_name(name, max_len) do
    if String.length(name) > max_len do
      String.slice(name, 0, max_len - 1) <> "…"
    else
      name
    end
  end
end
