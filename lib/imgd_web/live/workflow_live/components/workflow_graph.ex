defmodule ImgdWeb.WorkflowLive.Components.WorkflowGraph do
  @moduledoc """
  A LiveComponent that renders a workflow graph with execution status visualization.

  Supports:
  - Static workflow visualization
  - Live execution status updates (running, completed, failed, skipped)
  - Step timing display
  - Execution path highlighting
  """
  use Phoenix.LiveComponent

  alias Imgd.Workflows.GraphExtractor

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       graph_data: nil,
       error: nil,
       execution_steps: %{},
       trace_steps: [],
       current_execution: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Extract graph if workflow changed
    socket =
      if Map.has_key?(assigns, :workflow) do
        case GraphExtractor.extract(assigns.workflow) do
          {:ok, data} -> assign(socket, graph_data: data, error: nil)
          {:error, reason} -> assign(socket, graph_data: nil, error: reason)
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="workflow-graph-container rounded-xl border border-base-300 bg-base-200/60 p-3"
    >
      <%= if @error do %>
        <.error_state error={@error} />
      <% else %>
        <%= if @graph_data && length(@graph_data.nodes) > 0 do %>
          <div class="relative w-full overflow-x-auto">
            <svg
              class="w-full rounded-lg shadow-sm"
              viewBox={compute_viewbox(@graph_data)}
              preserveAspectRatio="xMidYMid meet"
              style="min-height: 280px; max-height: 500px;"
            >
              <defs>
                <.svg_defs />
              </defs>

              <%!-- Background grid --%>
              <rect x="0" y="0" width="100%" height="100%" fill="url(#workflow-grid)" rx="12" ry="12" />

              <%!-- Render edges first (behind nodes) --%>
              <%= for edge <- @graph_data.edges do %>
                <.edge
                  edge={edge}
                  layout={@graph_data.layout}
                  execution_steps={@execution_steps}
                />
              <% end %>

              <%!-- Render nodes --%>
              <%= for node <- @graph_data.nodes do %>
                <.graph_node
                  node={node}
                  layout={@graph_data.layout}
                  step_status={get_step_status(@execution_steps, node.id)}
                  trace_steps={@trace_steps}
                />
              <% end %>
            </svg>
          </div>

          <%!-- Legend --%>
          <.legend has_execution={map_size(@execution_steps) > 0} />
        <% else %>
          <.empty_state />
        <% end %>
      <% end %>
    </div>
    """
  end

  # SVG Definitions
  defp svg_defs(assigns) do
    ~H"""
    <%!-- Grid pattern --%>
    <pattern id="workflow-grid" width="32" height="32" patternUnits="userSpaceOnUse">
      <path d="M 32 0 L 0 0 0 32" fill="none" stroke="#e5e7eb" stroke-width="0.5" />
    </pattern>

    <%!-- Node shadow --%>
    <filter id="node-shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#000000" flood-opacity="0.12" />
    </filter>

    <%!-- Running glow --%>
    <filter id="running-glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="3" result="coloredBlur" />
      <feMerge>
        <feMergeNode in="coloredBlur" />
        <feMergeNode in="SourceGraphic" />
      </feMerge>
    </filter>

    <%!-- Arrowheads for different states --%>
    <marker id="arrowhead-default" markerWidth="8" markerHeight="8" refX="5" refY="4" orient="auto">
      <polygon points="0 0, 6 4, 0 8" fill="#cbd5e1" />
    </marker>
    <marker id="arrowhead-success" markerWidth="8" markerHeight="8" refX="5" refY="4" orient="auto">
      <polygon points="0 0, 6 4, 0 8" fill="#22c55e" />
    </marker>
    <marker id="arrowhead-failed" markerWidth="8" markerHeight="8" refX="5" refY="4" orient="auto">
      <polygon points="0 0, 6 4, 0 8" fill="#ef4444" />
    </marker>
    <marker id="arrowhead-running" markerWidth="8" markerHeight="8" refX="5" refY="4" orient="auto">
      <polygon points="0 0, 6 4, 0 8" fill="#3b82f6" />
    </marker>
    """
  end

  # Node rendering with execution status
  defp graph_node(assigns) do
    {x, y, w, h} = Map.get(assigns.layout, assigns.node.id, {0, 0, 180, 80})
    status = assigns.step_status
    colors = node_colors(assigns.node.type, status)

    # Find step data for this node
    step_data = find_step_data(assigns.trace_steps, assigns.node.id)

    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:w, w)
      |> assign(:h, h)
      |> assign(:colors, colors)
      |> assign(:status, status)
      |> assign(:step_data, step_data)

    ~H"""
    <g class="workflow-node" data-node-id={@node.id}>
      <%!-- Node card background --%>
      <rect
        x={@x}
        y={@y}
        width={@w}
        height={@h}
        rx="10"
        ry="10"
        fill={@colors.bg}
        stroke={@colors.border}
        stroke-width={if @status in [:running, :completed, :failed], do: "2.5", else: "1.2"}
        filter={if @status == :running, do: "url(#running-glow)", else: "url(#node-shadow)"}
      />

      <%!-- Status indicator circle --%>
      <%= if @status && @status != :none do %>
        <.status_indicator x={@x + @w - 16} y={@y + 12} status={@status} />
      <% end %>

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
      <text x={@x + 46} y={@y + 24} font-size="13" font-weight="600" fill={@colors.text}>
        {truncate_name(@node.name, 18)}
      </text>

      <%!-- Node type label --%>
      <text x={@x + 46} y={@y + 42} font-size="11" fill={@colors.subtext}>
        {node_type_label(@node.type)}
      </text>

      <%!-- Input/Output data display --%>
      <%= if @step_data do %>
        <% input_val = format_step_value(@step_data.input_snapshot) %>
        <% output_val = format_step_value(@step_data.output_snapshot) %>
        <% duration = @step_data.duration_ms %>

        <g class="execution-data">
          <%!-- Input value (left) --%>
          <text x={@x + 10} y={@y + @h - 26} font-size="10" fill={@colors.subtext} font-weight="500">
            ← {input_val}
          </text>

          <%!-- Output value (right) --%>
          <text
            x={@x + @w - 10}
            y={@y + @h - 26}
            text-anchor="end"
            font-size="10"
            fill={@colors.subtext}
            font-weight="500"
          >
            {output_val} →
          </text>
        </g>

        <%!-- Duration (top right, outside node) --%>
        <text
          x={@x + @w}
          y={@y - 8}
          text-anchor="end"
          font-size="10"
          fill={@colors.subtext}
          font-weight="500"
        >
          {duration}ms
        </text>
      <% end %>

      <%!-- Always show node hash at bottom --%>
      <text x={@x + 10} y={@y + @h - 10} font-size="9" fill={@colors.subtext} opacity="0.6">
        {truncate_name(to_string(@node.id), 16)}
      </text>

      <%!-- Running animation --%>
      <%= if @status == :running do %>
        <rect x={@x} y={@y + @h - 4} width={@w} height="4" rx="2" fill={@colors.border} opacity="0.3">
          <animate
            attributeName="width"
            values={"0;#{@w};0"}
            dur="1.5s"
            repeatCount="indefinite"
          />
        </rect>
      <% end %>
    </g>
    """
  end

  # Status indicator circle
  defp status_indicator(assigns) do
    {icon, bg_color, icon_color} =
      case assigns.status do
        :completed -> {"✓", "#22c55e", "#ffffff"}
        :failed -> {"!", "#ef4444", "#ffffff"}
        :running -> {"●", "#3b82f6", "#ffffff"}
        :retrying -> {"↻", "#f59e0b", "#ffffff"}
        :skipped -> {"○", "#9ca3af", "#ffffff"}
        _ -> {nil, nil, nil}
      end

    assigns =
      assigns
      |> assign(:icon, icon)
      |> assign(:bg_color, bg_color)
      |> assign(:icon_color, icon_color)

    ~H"""
    <%= if @icon do %>
      <circle cx={@x} cy={@y} r="10" fill={@bg_color} />
      <text
        x={@x}
        y={@y + 4}
        text-anchor="middle"
        font-size="11"
        font-weight="bold"
        fill={@icon_color}
      >
        {@icon}
      </text>
    <% end %>
    """
  end

  # Edge rendering with execution path highlighting
  defp edge(assigns) do
    from_pos = Map.get(assigns.layout, assigns.edge.from)
    to_pos = Map.get(assigns.layout, assigns.edge.to)

    if from_pos && to_pos do
      {from_x, from_y, from_w, from_h} = from_pos
      {to_x, to_y, _to_w, to_h} = to_pos

      start_x = from_x + from_w
      start_y = from_y + from_h / 2
      end_x = to_x
      end_y = to_y + to_h / 2

      dx = max(end_x - start_x, 40)
      c1_x = start_x + min(dx * 0.35, 60)
      c2_x = end_x - min(dx * 0.35, 60)

      path = "M#{start_x},#{start_y} C#{c1_x},#{start_y} #{c2_x},#{end_y} #{end_x},#{end_y}"

      # Determine edge status based on connected nodes
      from_status = get_step_status(assigns.execution_steps, assigns.edge.from)
      to_status = get_step_status(assigns.execution_steps, assigns.edge.to)
      edge_style = edge_style(from_status, to_status)

      assigns =
        assigns
        |> assign(:path, path)
        |> assign(:edge_style, edge_style)

      ~H"""
      <path
        d={@path}
        fill="none"
        stroke={@edge_style.color}
        stroke-width={@edge_style.width}
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-opacity={@edge_style.opacity}
        stroke-dasharray={@edge_style.dash}
        marker-end={"url(##{@edge_style.marker})"}
      />
      """
    else
      ~H""
    end
  end

  defp edge_style(from_status, to_status) do
    cond do
      from_status == :completed && to_status in [:completed, :running] ->
        %{color: "#22c55e", width: "2", opacity: "1", dash: "", marker: "arrowhead-success"}

      from_status == :completed && to_status == :failed ->
        %{color: "#ef4444", width: "2", opacity: "1", dash: "", marker: "arrowhead-failed"}

      from_status == :running || to_status == :running ->
        %{color: "#3b82f6", width: "2", opacity: "1", dash: "4,4", marker: "arrowhead-running"}

      from_status in [:completed, :failed] ->
        %{color: "#22c55e", width: "1.5", opacity: "0.7", dash: "", marker: "arrowhead-success"}

      true ->
        %{color: "#cbd5e1", width: "1.4", opacity: "0.8", dash: "", marker: "arrowhead-default"}
    end
  end

  # Error state
  defp error_state(assigns) do
    ~H"""
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
    """
  end

  # Empty state
  defp empty_state(assigns) do
    ~H"""
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
    """
  end

  # Legend
  defp legend(assigns) do
    ~H"""
    <div class="mt-3 flex flex-wrap items-center gap-2 text-[11px] text-base-content/60">
      <span class="mr-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/70">
        Legend
      </span>
      <.legend_chip label="Step" type={:step} />
      <.legend_chip label="Rule" type={:rule} />
      <.legend_chip label="Accumulator" type={:accumulator} />
      <.legend_chip label="State Machine" type={:state_machine} />
      <%= if @has_execution do %>
        <span class="mx-2 h-3 w-px bg-base-300"></span>
        <.status_legend_chip label="Running" status={:running} />
        <.status_legend_chip label="Completed" status={:completed} />
        <.status_legend_chip label="Failed" status={:failed} />
      <% end %>
    </div>
    """
  end

  defp legend_chip(assigns) do
    colors = node_colors(assigns.type, nil)
    assigns = assign(assigns, :colors, colors)

    ~H"""
    <div class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-100 px-2 py-0.5">
      <span class="inline-block size-2.5 rounded-full" style={"background-color: #{@colors.badge};"}>
      </span>
      <span>{@label}</span>
    </div>
    """
  end

  defp status_legend_chip(assigns) do
    {color, _} =
      case assigns.status do
        :running -> {"#3b82f6", "●"}
        :completed -> {"#22c55e", "✓"}
        :failed -> {"#ef4444", "!"}
        _ -> {"#9ca3af", "○"}
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <div class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-100 px-2 py-0.5">
      <span class="inline-block size-2.5 rounded-full" style={"background-color: #{@color};"}></span>
      <span>{@label}</span>
    </div>
    """
  end

  # Viewbox computation
  defp compute_viewbox(%{layout: layout}) when map_size(layout) == 0, do: "0 0 400 200"

  defp compute_viewbox(%{layout: layout}) do
    positions = Map.values(layout)
    max_x = positions |> Enum.map(fn {x, _y, w, _h} -> x + w end) |> Enum.max(fn -> 400 end)
    max_y = positions |> Enum.map(fn {_x, y, _w, h} -> y + h end) |> Enum.max(fn -> 200 end)
    "0 0 #{max_x + 80} #{max_y + 80}"
  end

  # Node colors with execution status
  defp node_colors(type, status) do
    base = base_node_colors(type)

    case status do
      :running ->
        Map.merge(base, %{border: "#3b82f6", bg: "#eff6ff"})

      :completed ->
        Map.merge(base, %{border: "#22c55e", bg: "#f0fdf4"})

      :failed ->
        Map.merge(base, %{border: "#ef4444", bg: "#fef2f2"})

      :retrying ->
        Map.merge(base, %{border: "#f59e0b", bg: "#fffbeb"})

      :skipped ->
        Map.merge(base, %{border: "#9ca3af", bg: "#f9fafb"})

      _ ->
        base
    end
  end

  defp base_node_colors(:step) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      badge: "#2563eb",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp base_node_colors(:rule) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      badge: "#059669",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp base_node_colors(:accumulator) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      badge: "#d97706",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp base_node_colors(:state_machine) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      badge: "#7c3aed",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  defp base_node_colors(_) do
    %{
      bg: "#ffffff",
      border: "#e5e7eb",
      badge: "#6b7280",
      badge_text: "#ffffff",
      text: "#111827",
      subtext: "#6b7280"
    }
  end

  # Helper functions
  defp get_step_status(execution_steps, node_id) when is_map(execution_steps) do
    Map.get(execution_steps, node_id, nil)
  end

  defp get_step_status(_, _), do: nil

  # Find step data for a given node ID (step_hash)
  defp find_step_data(trace_steps, node_id) do
    Enum.find(trace_steps, fn step ->
      step.step_hash == node_id
    end)
  end

  # Format step value for display
  defp format_step_value(nil), do: "?"

  defp format_step_value(snapshot) do
    # The data is nested under snapshot["value"]["value"]["data"]
    case get_in(snapshot, ["value", "value", "data"]) do
      nil -> "?"
      value when is_number(value) -> to_string(value)
      value when is_binary(value) and byte_size(value) <= 8 -> value
      _ -> "⋯"
    end
  end

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
