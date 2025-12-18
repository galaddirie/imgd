defmodule ImgdWeb.WorkflowLive.RunnerComponents do
  @moduledoc """
  Function components for the workflow runner LiveView UI.
  """
  use ImgdWeb, :html

  alias Imgd.Executions.Execution

  import ImgdWeb.Formatters

  # ============================================================================
  # Component: Execution Status Badge
  # ============================================================================

  def execution_status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%= if @execution do %>
        <span class={["badge", execution_badge_class(@execution.status)]}>
          {@execution.status}
        </span>
        <%= if @execution.status == :running do %>
          <span class="loading loading-spinner loading-xs"></span>
        <% end %>
      <% else %>
        <span class="badge badge-ghost">Ready</span>
      <% end %>
    </div>
    """
  end

  defp execution_badge_class(:pending), do: "badge-warning"
  defp execution_badge_class(:running), do: "badge-info"
  defp execution_badge_class(:completed), do: "badge-success"
  defp execution_badge_class(:failed), do: "badge-error"
  defp execution_badge_class(:cancelled), do: "badge-neutral"
  defp execution_badge_class(:timeout), do: "badge-error"
  defp execution_badge_class(_), do: "badge-ghost"

  # ============================================================================
  # Component: Run Panel
  # ============================================================================

  attr :run_form, :map, required: true
  attr :demo_inputs, :list, default: []
  attr :selected_demo, :map, default: nil
  attr :running?, :boolean, default: false
  attr :can_run?, :boolean, default: true
  attr :run_form_error, :string, default: nil
  attr :versions, :list, default: []
  attr :selected_version_id, :string, default: "draft"

  def run_panel(assigns) do
    ~H"""
    <.form
      for={@run_form}
      id="run-config-form"
      phx-change="update_payload"
      phx-submit="run_workflow"
      class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 mb-6"
    >
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="flex items-center justify-center w-10 h-10 rounded-xl bg-primary/10 text-primary">
            <.icon name="hero-rocket-launch" class="size-5" />
          </div>
          <div class="space-y-0.5">
            <p class="text-sm font-semibold text-base-content">Execution Settings</p>
            <p class="text-xs text-base-content/60">
              Choose source version and provide input payload.
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="badge badge-ghost badge-sm">Trigger: Manual</span>
          <span class={["badge badge-sm", @running? && "badge-info", @running? || "badge-ghost"]}>
            {(@running? && "Running") || "Ready"}
          </span>
        </div>
      </div>

      <div class="p-4 space-y-4">
        <div class="grid grid-cols-1 xl:grid-cols-3 gap-4">
          <div class="xl:col-span-2 space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@run_form[:version_id]}
                type="select"
                label="Workflow Version"
                options={[
                  {"Draft (Current Changes)", "draft"}
                  | Enum.map(
                      @versions,
                      &{"v#{&1.version_tag} - #{format_relative_time(&1.published_at)}", &1.id}
                    )
                ]}
                class="select select-bordered w-full select-sm h-10"
              />
            </div>

            <div class="space-y-2">
              <.input
                field={@run_form[:data]}
                type="textarea"
                label="Initial data (JSON)"
                rows="8"
                spellcheck="false"
                class="textarea w-full font-mono text-sm leading-relaxed"
                placeholder='{"user_id": 1}'
              />
              <div class="flex items-center justify-between text-xs text-base-content/60">
                <span>Blank value sends an empty map.</span>
                <span :if={@run_form_error} class="text-error font-medium">
                  {@run_form_error}
                </span>
              </div>
            </div>
          </div>

          <div class="space-y-3">
            <div class="flex items-center gap-2 text-sm font-semibold text-base-content">
              <.icon name="hero-sparkles" class="size-4 opacity-70" />
              <span>Demo payloads</span>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={demo <- @demo_inputs}
                type="button"
                class={[
                  "btn btn-outline btn-xs",
                  @selected_demo && @selected_demo.id == demo.id && "btn-primary"
                ]}
                phx-click="select_demo_input"
                phx-value-id={demo.id}
                title={demo.description || "Load preset input"}
              >
                {demo.label}
              </button>
            </div>

            <div class="rounded-xl bg-base-200/60 border border-base-200 p-3 space-y-2">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                Selected preset
              </p>
              <%= if @selected_demo do %>
                <p class="text-sm text-base-content">{@selected_demo.label}</p>
                <p :if={@selected_demo.description} class="text-xs text-base-content/60">
                  {@selected_demo.description}
                </p>
                <pre class="mt-2 max-h-32 overflow-auto rounded-lg bg-base-300/50 p-2 text-[11px] font-mono"><%=
                  format_json_preview(@selected_demo.data)
                %></pre>
              <% else %>
                <p class="text-xs text-base-content/60">Start typing or pick a preset.</p>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div class="flex items-center gap-2 text-xs text-base-content/70">
            <.icon name="hero-light-bulb" class="size-4" />
            <span>
              Double-click any node to configure its inputs. Right-click for more options.
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="submit"
              class={[
                "btn btn-primary btn-sm gap-2",
                (@running? or not @can_run?) && "btn-disabled"
              ]}
              disabled={@running? or not @can_run?}
            >
              <.icon
                name={if @running?, do: "hero-arrow-path", else: "hero-play"}
                class={"size-4#{if @running?, do: " animate-spin", else: ""}"}
              />
              <span>{if @running?, do: "Running...", else: "Run workflow"}</span>
            </button>
            <span :if={not @can_run?} class="text-xs text-warning">
              Add nodes to the workflow to enable runs.
            </span>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  # ============================================================================
  # Component: DAG Panel
  # ============================================================================

  attr :nodes, :list, required: true
  attr :layout, :map, required: true
  attr :edges, :list, required: true
  attr :meta, :map, required: true
  attr :node_map, :map, required: true
  attr :node_states, :map, required: true
  attr :selected_node_id, :string, default: nil
  attr :pins_with_status, :map, default: %{}

  def dag_panel(assigns) do
    edge_states = compute_edge_states(assigns.edges, assigns.node_states)
    assigns = assign(assigns, :edge_states, edge_states)

    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 overflow-hidden">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-squares-2x2" class="size-4 opacity-70" /> Workflow Graph
        </h2>
        <div class="flex items-center gap-3">
          <.execution_progress_indicator
            node_states={@node_states}
            node_count={length(@nodes)}
          />
          <span class="text-xs text-base-content/60">
            {length(@nodes)} nodes
          </span>
        </div>
      </div>

      <div class="p-4 overflow-auto bg-base-200/30" style="max-height: 600px;">
        <%= if @nodes == [] or is_nil(@nodes) do %>
          <div class="flex flex-col items-center justify-center py-16 text-base-content/60">
            <.icon name="hero-cube-transparent" class="size-12 mb-3 opacity-50" />
            <p class="text-sm">No nodes in this workflow</p>
          </div>
        <% else %>
          <svg
            width={@meta.width}
            height={@meta.height}
            class="mx-auto"
            style="min-width: 100%;"
          >
            <defs>
              <marker
                id="arrowhead-default"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" class="fill-base-300" />
              </marker>
              <marker
                id="arrowhead-pending"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" class="fill-warning" />
              </marker>
              <marker
                id="arrowhead-running"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" class="fill-info" />
              </marker>
              <marker
                id="arrowhead-completed"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" class="fill-success" />
              </marker>
              <marker
                id="arrowhead-failed"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" class="fill-error" />
              </marker>
              <style>
                @keyframes dash-flow {
                  to { stroke-dashoffset: -20; }
                }
                .edge-running {
                  animation: dash-flow 0.5s linear infinite;
                }
              </style>
            </defs>

            <g class="edges">
              <%= for edge <- @edges do %>
                <% edge_status = Map.get(@edge_states, edge.id, :default) %>
                <.dag_edge edge={edge} status={edge_status} />
              <% end %>
            </g>

            <g class="nodes">
              <%= for node <- @nodes do %>
                <% pos = Map.get(@layout, node.id, %{x: 0, y: 0}) %>
                <% state = Map.get(@node_states, node.id, %{}) %>
                <% pin_info = Map.get(@pins_with_status, node.id) %>
                <.dag_node
                  node={node}
                  position={pos}
                  state={state}
                  selected={@selected_node_id == node.id}
                  pinned={pin_info != nil}
                  pin_stale={pin_info && pin_info["stale"]}
                />
              <% end %>
            </g>
          </svg>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Component: DAG Edge
  # ============================================================================

  attr :edge, :map, required: true
  attr :status, :atom, required: true

  defp dag_edge(assigns) do
    ~H"""
    <g class="edge-group">
      <path
        d={@edge.path}
        fill="none"
        stroke-width={if @status == :running, do: "3", else: "2"}
        class={[
          edge_stroke_class(@status),
          @status == :running && "edge-running"
        ]}
        stroke-dasharray={if @status == :running, do: "5,5", else: "none"}
        marker-end={"url(#arrowhead-#{@status})"}
      />

      <%= if @status == :running do %>
        <circle r="4" class="fill-info">
          <animateMotion dur="1s" repeatCount="indefinite" path={@edge.path} />
        </circle>
      <% end %>
    </g>
    """
  end

  defp edge_stroke_class(:default), do: "stroke-base-300"
  defp edge_stroke_class(:pending), do: "stroke-warning"
  defp edge_stroke_class(:running), do: "stroke-info"
  defp edge_stroke_class(:completed), do: "stroke-success"
  defp edge_stroke_class(:failed), do: "stroke-error"
  defp edge_stroke_class(_), do: "stroke-base-300"

  defp compute_edge_states(edges, node_states) do
    Map.new(edges, fn edge ->
      source_status = get_in(node_states, [edge.source_node_id, :status])
      edge_status = source_status || :default
      {edge.id, edge_status}
    end)
  end

  # ============================================================================
  # Component: Execution Progress Indicator
  # ============================================================================

  attr :node_states, :map, required: true
  attr :node_count, :integer, required: true

  defp execution_progress_indicator(assigns) do
    completed = assigns.node_states |> Enum.count(fn {_, s} -> s[:status] == :completed end)
    running = assigns.node_states |> Enum.count(fn {_, s} -> s[:status] == :running end)
    failed = assigns.node_states |> Enum.count(fn {_, s} -> s[:status] == :failed end)

    assigns = assign(assigns, completed: completed, running: running, failed: failed)

    ~H"""
    <div :if={@completed > 0 or @running > 0 or @failed > 0} class="flex items-center gap-2">
      <div class="flex items-center gap-1">
        <span :if={@running > 0} class="flex items-center gap-1 text-xs text-info">
          <span class="loading loading-spinner loading-xs"></span>
          {@running}
        </span>
        <span :if={@completed > 0} class="flex items-center gap-1 text-xs text-success">
          <.icon name="hero-check-circle" class="size-3" />
          {@completed}
        </span>
        <span :if={@failed > 0} class="flex items-center gap-1 text-xs text-error">
          <.icon name="hero-x-circle" class="size-3" />
          {@failed}
        </span>
      </div>
      <span class="text-xs text-base-content/40">/ {@node_count}</span>
    </div>
    """
  end

  # ============================================================================
  # Component: DAG Node (with double-click support)
  # ============================================================================

  attr :node, :map, required: true
  attr :position, :map, required: true
  attr :state, :map, required: true
  attr :selected, :boolean, default: false
  attr :pinned, :boolean, default: false
  attr :pin_stale, :boolean, default: false

  def dag_node(assigns) do
    ~H"""
    <g
      transform={"translate(#{@position.x}, #{@position.y})"}
      phx-click="select_node"
      phx-value-node-id={@node.id}
      class="cursor-pointer group"
    >
      <%!-- Invisible larger hit area for context menu --%>
      <rect
        width="220"
        height="100"
        x="-10"
        y="-10"
        fill="transparent"
        phx-hook=".NodeContextMenu"
        id={"node-hitarea-#{@node.id}"}
        data-node-id={@node.id}
      />

      <%!-- Glow effect --%>
      <%= if @state[:status] == :running or @selected do %>
        <rect
          width="200"
          height="80"
          rx="14"
          x="-2"
          y="-2"
          class={[
            "transition-all duration-200",
            @state[:status] == :running && "fill-info/20",
            @selected && @state[:status] != :running && "fill-primary/20"
          ]}
        />
      <% end %>

      <%!-- Pin highlight border --%>
      <%= if @pinned do %>
        <rect
          width="204"
          height="84"
          rx="14"
          x="-2"
          y="-2"
          fill="none"
          stroke-width="2"
          stroke-dasharray="6,3"
          class={[(@pin_stale && "stroke-warning") || "stroke-primary"]}
        />
      <% end %>

      <%!-- Node background --%>
      <rect
        width="200"
        height="80"
        rx="12"
        class={[
          "transition-all duration-200",
          node_bg_class(@state[:status], @selected)
        ]}
        stroke-width={if @selected, do: "3", else: "2"}
      />

      <%!-- Pin indicator badge --%>
      <%= if @pinned do %>
        <g transform="translate(176, -8)" class="pointer-events-none">
          <circle cx="12" cy="12" r="14" class={[(@pin_stale && "fill-warning") || "fill-primary"]} />
          <text
            x="12"
            y="13"
            text-anchor="middle"
            dominant-baseline="middle"
            class="text-xs fill-primary-content select-none"
          >
            📌
          </text>
        </g>
      <% end %>

      <%!-- Hover action bar --%>
      <foreignObject
        x="8"
        y="-32"
        width="184"
        height="32"
        class="opacity-0 group-hover:opacity-100 transition duration-150 pointer-events-none group-hover:pointer-events-auto"
      >
        <div class="w-full flex items-center justify-end gap-1.5">
          <button
            type="button"
            phx-click="open_node_config"
            phx-value-node-id={@node.id}
            class="px-2 py-1 rounded-full text-xs font-medium shadow-sm bg-base-100 border border-base-300 hover:bg-base-200 transition flex items-center gap-1"
            title="Configure node"
          >
            <.icon name="hero-cog-6-tooth" class="size-3" /> Configure
          </button>
          <button
            type="button"
            phx-click="execute_to_node"
            phx-value-node-id={@node.id}
            class="px-2 py-1 rounded-full text-xs font-semibold shadow-sm bg-primary text-primary-content hover:bg-primary/90 transition"
            title="Run to this node"
          >
            Run to Here
          </button>
        </div>
      </foreignObject>

      <%!-- Status indicator --%>
      <g transform="translate(16, 16)">
        <%= if @state[:status] == :running do %>
          <circle cx="0" cy="0" r="8" class="fill-info/20" />
          <circle cx="0" cy="0" r="6" class="fill-info">
            <animate attributeName="r" values="4;6;4" dur="1s" repeatCount="indefinite" />
          </circle>
          <circle cx="0" cy="0" r="10" class="fill-info/30">
            <animate attributeName="r" values="6;12;6" dur="1s" repeatCount="indefinite" />
            <animate attributeName="opacity" values="0.5;0;0.5" dur="1s" repeatCount="indefinite" />
          </circle>
        <% else %>
          <%= if @pinned and not @state[:status] do %>
            <circle cx="0" cy="0" r="6" class={[(@pin_stale && "fill-warning") || "fill-primary/60"]} />
          <% else %>
            <circle cx="0" cy="0" r="6" class={node_status_indicator_class(@state[:status])} />
          <% end %>
        <% end %>
      </g>

      <%!-- Node name --%>
      <text x="32" y="20" class="text-sm font-medium fill-current" dominant-baseline="middle">
        {truncate_text(@node.name, 18)}
      </text>

      <%!-- Node type + pin label --%>
      <text x="16" y="44" class="text-xs fill-current opacity-60">
        {node_type_label(@node.type_id)}
        <%= if @pinned do %>
          <tspan class="fill-primary">(pinned)</tspan>
        <% end %>
      </text>

      <%!-- Duration display --%>
      <%= if @state[:duration_us] do %>
        <g transform="translate(16, 62)">
          <rect
            width={duration_bar_width(@state[:duration_us])}
            height="4"
            rx="2"
            class="fill-success/40"
          />
          <text
            x={duration_bar_width(@state[:duration_us]) + 8}
            y="4"
            class="text-[10px] fill-current opacity-50"
            dominant-baseline="middle"
          >
            {format_duration(@state[:duration_us])}
          </text>
        </g>
      <% else %>
        <%= if @state[:status] == :running do %>
          <text x="16" y="64" class="text-[10px] fill-info animate-pulse">
            Running...
          </text>
        <% end %>
        <%= if @pinned and not @state[:status] do %>
          <text x="16" y="64" class="text-[10px] fill-primary/60">
            Using pinned data
          </text>
        <% end %>
      <% end %>

      <%!-- Error indicator --%>
      <%= if @state[:status] == :failed do %>
        <g transform="translate(172, 4)">
          <circle cx="12" cy="12" r="12" class="fill-error" />
          <text x="12" y="16" text-anchor="middle" class="text-sm fill-error-content font-bold">
            !
          </text>
        </g>
      <% end %>

      <%!-- Success checkmark --%>
      <%= if @state[:status] == :completed do %>
        <g transform="translate(172, 4)">
          <circle cx="12" cy="12" r="12" class="fill-success" />
          <path
            d="M8 12 L11 15 L16 9"
            stroke="currentColor"
            stroke-width="2"
            fill="none"
            class="text-success-content"
          />
        </g>
      <% end %>
    </g>

    <%!-- Colocated hook for context menu --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NodeContextMenu">
      export default {
        mounted() {
          this.el.addEventListener("dblclick", (e) => {
            e.stopPropagation();
            const nodeId = this.el.dataset.nodeId;
            this.pushEvent("open_node_config", { "node-id": nodeId });
          });

          this.el.addEventListener("contextmenu", (e) => {
            e.preventDefault();
            e.stopPropagation();
            const nodeId = this.el.dataset.nodeId;
            const rect = this.el.getBoundingClientRect();
            this.pushEvent("open_context_menu", {
              "node-id": nodeId,
              x: e.clientX,
              y: e.clientY
            });
          });
        }
      }
    </script>
    """
  end

  # ============================================================================
  # Component: Node Context Menu
  # ============================================================================

  attr :node_id, :string, required: true
  attr :node_name, :string, required: true
  attr :pinned, :boolean, default: false
  attr :pin_stale, :boolean, default: false
  attr :has_output, :boolean, default: false
  attr :position, :map, required: true

  def node_context_menu(assigns) do
    ~H"""
    <div
      id={"context-menu-#{@node_id}"}
      class="fixed z-50 bg-base-100 border border-base-300 rounded-xl shadow-xl py-2 min-w-[220px]"
      style={"left: #{@position.x}px; top: #{@position.y}px;"}
      phx-click-away="close_context_menu"
    >
      <div class="px-3 py-1.5 border-b border-base-200 mb-1">
        <p class="text-sm font-medium text-base-content truncate">{@node_name}</p>
      </div>

      <%!-- Primary Actions --%>
      <div class="px-1">
        <button
          type="button"
          class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-base-200 rounded-lg transition-colors"
          phx-click="open_node_config"
          phx-value-node-id={@node_id}
        >
          <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/70" />
          <span>Configure Node</span>
          <span class="ml-auto text-xs text-base-content/50">Double-click</span>
        </button>

        <button
          type="button"
          class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-base-200 rounded-lg transition-colors"
          phx-click="execute_to_node"
          phx-value-node-id={@node_id}
        >
          <.icon name="hero-play" class="size-4 text-success" />
          <span>Execute to Here</span>
          <span class="ml-auto text-xs text-base-content/50">Run upstream</span>
        </button>
      </div>

      <div class="border-t border-base-200 my-1"></div>

      <%!-- Pin Actions --%>
      <div class="px-1">
        <%= if @pinned do %>
          <button
            type="button"
            class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-base-200 rounded-lg transition-colors"
            phx-click="open_node_config"
            phx-value-node-id={@node_id}
          >
            <.icon name="hero-eye" class="size-4 text-base-content/70" />
            <span>View Pinned Data</span>
            <%= if @pin_stale do %>
              <span class="ml-auto badge badge-warning badge-xs">stale</span>
            <% end %>
          </button>
          <button
            type="button"
            class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-error/10 text-error rounded-lg transition-colors"
            phx-click="clear_pin"
            phx-value-node-id={@node_id}
          >
            <.icon name="hero-x-mark" class="size-4" />
            <span>Remove Pin</span>
          </button>
        <% else %>
          <button
            type="button"
            class="w-full flex items-center gap-2 px-3 py-2 text-sm text-left hover:bg-base-200 rounded-lg transition-colors"
            phx-click="open_node_config"
            phx-value-node-id={@node_id}
          >
            <.icon name="hero-bookmark" class="size-4 text-primary" />
            <span>Pin Output...</span>
            <span class="ml-auto text-xs text-base-content/50">in modal</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Component: Pins Summary Panel
  # ============================================================================

  attr :workflow, :map, required: true
  attr :pins_with_status, :map, required: true

  def pins_summary_panel(assigns) do
    pin_count = map_size(assigns.pins_with_status)
    stale_count = Enum.count(assigns.pins_with_status, fn {_, p} -> p["stale"] end)
    orphan_count = Enum.count(assigns.pins_with_status, fn {_, p} -> not p["node_exists"] end)

    assigns =
      assigns
      |> assign(:pin_count, pin_count)
      |> assign(:stale_count, stale_count)
      |> assign(:orphan_count, orphan_count)

    ~H"""
    <div :if={@pin_count > 0} class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-bookmark" class="size-4 opacity-70" /> Pinned Outputs
          <span class="badge badge-primary badge-sm">{@pin_count}</span>
        </h2>
        <div class="flex items-center gap-2">
          <%= if @stale_count > 0 do %>
            <span class="badge badge-warning badge-sm">{@stale_count} stale</span>
          <% end %>
          <%= if @orphan_count > 0 do %>
            <span class="badge badge-error badge-sm">{@orphan_count} orphaned</span>
          <% end %>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="clear_all_pins"
            data-confirm="Remove all pinned outputs?"
          >
            Clear all
          </button>
        </div>
      </div>
      <div class="p-3 space-y-2 max-h-48 overflow-y-auto">
        <%= for {node_id, pin} <- @pins_with_status do %>
          <div class={[
            "flex items-center justify-between p-2 rounded-lg",
            pin["stale"] && "bg-warning/10",
            not pin["node_exists"] && "bg-error/10",
            pin["node_exists"] && not pin["stale"] && "bg-base-200/50"
          ]}>
            <div class="flex items-center gap-2 min-w-0">
              <.icon
                name={
                  cond do
                    not pin["node_exists"] -> "hero-exclamation-triangle"
                    pin["stale"] -> "hero-exclamation-circle"
                    true -> "hero-bookmark-solid"
                  end
                }
                class={
                  [
                    "size-4 flex-shrink-0",
                    not pin["node_exists"] && "text-error",
                    pin["stale"] && pin["node_exists"] && "text-warning",
                    pin["node_exists"] && not pin["stale"] && "text-primary"
                  ]
                  |> Enum.filter(& &1)
                  |> Enum.join(" ")
                }
              />
              <div class="min-w-0">
                <p class="text-sm font-medium truncate">{pin["label"] || node_id}</p>
                <p class="text-xs text-base-content/60">
                  {format_relative_time(pin["pinned_at"])}
                </p>
              </div>
            </div>
            <div class="flex items-center gap-1">
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="open_node_config"
                phx-value-node-id={node_id}
                title="View pinned data"
              >
                <.icon name="hero-eye" class="size-3" />
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                phx-click="clear_pin"
                phx-value-node-id={node_id}
                title="Remove pin"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Component: Node Details Panel
  # ============================================================================

  attr :node_map, :map, required: true
  attr :node_states, :map, required: true
  attr :selected_node_id, :string, default: nil

  def node_details_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-cube" class="size-4 opacity-70" /> Node Details
        </h2>
        <%= if @selected_node_id do %>
          <button
            type="button"
            phx-click="clear_selection"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        <% end %>
      </div>

      <div class="p-4 overflow-auto" style="max-height: 600px;">
        <%= if @selected_node_id do %>
          <% node = Map.get(@node_map, @selected_node_id) %>
          <% state = Map.get(@node_states, @selected_node_id, %{}) %>

          <div class="space-y-4">
            <div>
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-medium text-base-content">{node.name}</h3>
                  <p class="text-xs text-base-content/60 mt-1">
                    Type: {node_type_label(node.type_id)}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <%= if state[:status] do %>
                    <span class={["badge badge-sm", node_status_badge_class(state[:status])]}>
                      {state[:status]}
                    </span>
                  <% end %>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="open_node_config"
                    phx-value-node-id={@selected_node_id}
                    title="Configure node"
                  >
                    <.icon name="hero-cog-6-tooth" class="size-4" />
                  </button>
                </div>
              </div>
              <p class="text-xs font-mono text-base-content/40 mt-2">
                ID: {node.id}
              </p>
            </div>

            <%= if state[:started_at] || state[:duration_us] do %>
              <div class="flex items-center gap-4 py-2 px-3 bg-base-200/50 rounded-lg">
                <%= if state[:duration_us] do %>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-clock" class="size-4 text-base-content/60" />
                    <span class="text-sm font-medium">{format_duration(state[:duration_us])}</span>
                  </div>
                <% end %>
                <%= if state[:started_at] do %>
                  <div class="text-xs text-base-content/60">
                    Started: {format_time(state[:started_at])}
                  </div>
                <% end %>
              </div>
            <% end %>

            <.data_section
              title="Input Data"
              data={state[:input_data]}
              empty_message="No input data captured"
            />

            <.data_section
              title="Output Data"
              data={state[:output_data]}
              empty_message="No output data yet"
            />

            <%= if state[:error] do %>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-error mb-2 flex items-center gap-1">
                  <.icon name="hero-exclamation-triangle" class="size-3" /> Error
                </p>
                <pre class="text-xs bg-error/10 text-error p-3 rounded-lg overflow-auto max-h-40 border border-error/20"><%=
                  format_json_preview(state[:error])
                %></pre>
              </div>
            <% end %>

            <details class="collapse collapse-arrow bg-base-200/30 rounded-lg">
              <summary class="collapse-title text-xs font-semibold uppercase tracking-wide text-base-content/60 min-h-0 py-2 px-3">
                Configuration
              </summary>
              <div class="collapse-content px-3 pb-3">
                <pre class="text-xs bg-base-200/60 p-2 rounded-lg overflow-auto max-h-40"><%=
                  format_json_preview(node.config)
                %></pre>
              </div>
            </details>
          </div>
        <% else %>
          <div class="text-center py-8 text-base-content/60">
            <.icon name="hero-cursor-arrow-rays" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">Click a node to view details</p>
            <p class="text-xs mt-1 opacity-70">Double-click to configure</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Component: Trace Log Panel
  # ============================================================================

  attr :trace_log, :list, required: true
  attr :trace_log_count, :integer, required: true

  def trace_log_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-document-text" class="size-4 opacity-70" /> Trace Log
        </h2>
        <span class="badge badge-ghost badge-sm">{@trace_log_count} entries</span>
      </div>

      <div
        id="trace-log-container"
        class="p-2 overflow-auto font-mono text-xs"
        style="max-height: 400px;"
        phx-update="stream"
        phx-hook=".ScrollToBottom"
      >
        <div
          :for={{dom_id, entry} <- @trace_log}
          id={dom_id}
          class={["py-1.5 px-2 rounded mb-0.5", trace_log_entry_class(entry.level)]}
        >
          <span class="text-base-content/40">
            {format_log_timestamp(entry.timestamp)}
          </span>
          <span class={["mx-1", trace_log_level_class(entry.level)]}>
            [{entry.level}]
          </span>
          <span class="text-base-content">
            {entry.message}
          </span>
          <%= if entry.data && entry.data != %{} do %>
            <span class="text-base-content/50 ml-1">
              {format_log_data(entry.data)}
            </span>
          <% end %>
        </div>

        <div
          :if={@trace_log_count == 0}
          class="text-center py-8 text-base-content/60"
        >
          <.icon name="hero-document-text" class="size-8 mx-auto mb-2 opacity-30" />
          <p class="text-sm">No log entries yet</p>
          <p class="text-xs mt-1">Run the workflow to see trace output</p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() {
            this.scrollToBottom()
            this.autoScroll = true

            this.el.addEventListener('scroll', () => {
              const { scrollTop, scrollHeight, clientHeight } = this.el
              this.autoScroll = scrollTop + clientHeight >= scrollHeight - 50
            })
          },

          updated() {
            if (this.autoScroll) {
              this.scrollToBottom()
            }
          },

          scrollToBottom() {
            requestAnimationFrame(() => {
              this.el.scrollTop = this.el.scrollHeight
            })
          }
        }
      </script>
    </div>
    """
  end

  # ============================================================================
  # Component: Execution Metadata Panel
  # ============================================================================

  attr :execution, Execution, required: true

  def execution_metadata_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 mt-6">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-information-circle" class="size-4 opacity-70" /> Execution Details
        </h2>
      </div>

      <div class="p-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
          <div>
            <p class="text-xs text-base-content/60 mb-1">Execution ID</p>
            <p class="font-mono text-sm">{short_id(@execution.id)}</p>
          </div>
          <div>
            <p class="text-xs text-base-content/60 mb-1">Status</p>
            <span class={["badge", execution_badge_class(@execution.status)]}>
              {@execution.status}
            </span>
          </div>
          <div>
            <p class="text-xs text-base-content/60 mb-1">Started</p>
            <p class="text-sm">{formatted_timestamp(@execution.started_at)}</p>
          </div>
          <div>
            <p class="text-xs text-base-content/60 mb-1">Duration</p>
            <p class="text-sm font-medium">{format_duration(Execution.duration_us(@execution))}</p>
          </div>
        </div>

        <div class="flex items-center justify-end">
          <.link
            navigate={~p"/workflows/#{@execution.workflow_id}/executions/#{@execution.id}"}
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-eye" class="size-4" /> View Full Details
          </.link>
        </div>

        <%= if @execution.error do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-error mb-2 flex items-center gap-1">
              <.icon name="hero-exclamation-triangle" class="size-3" /> Error Details
            </p>
            <pre class="text-xs bg-error/10 text-error p-3 rounded-lg overflow-auto max-h-40 border border-error/20"><%=
              format_json_preview(@execution.error)
            %></pre>
          </div>
        <% end %>

        <%= if @execution.output && @execution.output != %{} do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2 flex items-center gap-1">
              <.icon name="hero-document-check" class="size-3" /> Final Output
            </p>
            <pre class="text-xs bg-base-200/60 p-3 rounded-lg overflow-auto max-h-40 border border-base-200"><%=
              format_json_preview(@execution.output)
            %></pre>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Helper Components
  # ============================================================================

  attr :title, :string, required: true
  attr :data, :any, default: nil
  attr :empty_message, :string, default: "No data"

  defp data_section(assigns) do
    has_data = assigns.data && assigns.data != %{} && assigns.data != nil
    assigns = assign(assigns, :has_data, has_data)

    ~H"""
    <div>
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2 flex items-center gap-1">
        <%= if @title == "Input Data" do %>
          <.icon name="hero-arrow-down-on-square" class="size-3" />
        <% else %>
          <.icon name="hero-arrow-up-on-square" class="size-3" />
        <% end %>
        {@title}
      </p>
      <%= if @has_data do %>
        <pre class="text-xs bg-base-200/60 p-3 rounded-lg overflow-auto max-h-48 border border-base-200"><%=
          format_json_preview(@data)
        %></pre>
      <% else %>
        <p class="text-xs text-base-content/40 italic py-2">{@empty_message}</p>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp node_bg_class(nil, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(nil, true), do: "fill-base-100 stroke-primary"
  defp node_bg_class(:pending, false), do: "fill-warning/5 stroke-warning/50"
  defp node_bg_class(:pending, true), do: "fill-warning/10 stroke-primary"
  defp node_bg_class(:queued, false), do: "fill-warning/5 stroke-warning/50"
  defp node_bg_class(:queued, true), do: "fill-warning/10 stroke-primary"
  defp node_bg_class(:running, _), do: "fill-info/10 stroke-info"
  defp node_bg_class(:completed, false), do: "fill-success/10 stroke-success"
  defp node_bg_class(:completed, true), do: "fill-success/15 stroke-primary"
  defp node_bg_class(:failed, false), do: "fill-error/10 stroke-error"
  defp node_bg_class(:failed, true), do: "fill-error/15 stroke-primary"
  defp node_bg_class(_, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(_, true), do: "fill-base-100 stroke-primary"

  defp node_status_indicator_class(nil), do: "fill-base-300"
  defp node_status_indicator_class(:pending), do: "fill-warning"
  defp node_status_indicator_class(:queued), do: "fill-warning"
  defp node_status_indicator_class(:running), do: "fill-info"
  defp node_status_indicator_class(:completed), do: "fill-success"
  defp node_status_indicator_class(:failed), do: "fill-error"
  defp node_status_indicator_class(_), do: "fill-base-300"

  defp node_status_badge_class(:pending), do: "badge-warning"
  defp node_status_badge_class(:queued), do: "badge-warning"
  defp node_status_badge_class(:running), do: "badge-info"
  defp node_status_badge_class(:completed), do: "badge-success"
  defp node_status_badge_class(:failed), do: "badge-error"
  defp node_status_badge_class(_), do: "badge-ghost"

  defp node_type_label(type_id) do
    type_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp truncate_text(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len - 1) <> "…"
  end

  defp truncate_text(text, _), do: text

  defp duration_bar_width(us) when us < 1000, do: 20
  defp duration_bar_width(us) when us < 10_000, do: 40
  defp duration_bar_width(us) when us < 100_000, do: 60
  defp duration_bar_width(us) when us < 1_000_000, do: 80
  defp duration_bar_width(_), do: 100

  defp format_duration(nil), do: ""
  defp format_duration(us) when us < 1000, do: "#{us}μs"
  defp format_duration(us) when us < 1_000_000, do: "#{Float.round(us / 1000, 2)}ms"
  defp format_duration(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp format_time(nil), do: "-"
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_json_preview(data) when is_map(data) or is_list(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> truncate_json(json, 800)
      _ -> inspect(data, pretty: true, limit: 20)
    end
  end

  defp format_json_preview(data), do: inspect(data, pretty: true, limit: 20)

  defp truncate_json(json, max_len) when byte_size(json) > max_len do
    String.slice(json, 0, max_len) <> "\n... (truncated)"
  end

  defp truncate_json(json, _), do: json

  defp trace_log_entry_class(:error), do: "bg-error/10 border-l-2 border-error"
  defp trace_log_entry_class(:success), do: "bg-success/10 border-l-2 border-success"
  defp trace_log_entry_class(:warning), do: "bg-warning/10 border-l-2 border-warning"
  defp trace_log_entry_class(_), do: "hover:bg-base-200/50 border-l-2 border-transparent"

  defp trace_log_level_class(:error), do: "text-error font-semibold"
  defp trace_log_level_class(:success), do: "text-success font-semibold"
  defp trace_log_level_class(:warning), do: "text-warning"
  defp trace_log_level_class(_), do: "text-info"

  defp format_log_timestamp(nil), do: "--:--:--"

  defp format_log_timestamp(dt),
    do:
      Calendar.strftime(dt, "%H:%M:%S.") <>
        String.pad_leading("#{dt.microsecond |> elem(0) |> div(1000)}", 3, "0")

  defp format_log_data(data) when is_map(data) and map_size(data) == 0, do: ""

  defp format_log_data(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map(fn {k, v} -> "#{k}=#{format_log_value(v)}" end)
    |> Enum.join(" ")
  end

  defp format_log_data(_), do: ""

  defp format_log_value(v) when is_binary(v) and byte_size(v) > 30,
    do: String.slice(v, 0, 30) <> "..."

  defp format_log_value(v) when is_map(v), do: "{...}"
  defp format_log_value(v) when is_list(v), do: "[#{length(v)} items]"
  defp format_log_value(v), do: inspect(v, limit: 3)

  defp format_relative_time(nil), do: "unknown time"

  defp format_relative_time(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _} -> format_relative_time(dt)
      _ -> datetime_str
    end
  end

  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86400)} days ago"
    end
  end
end
