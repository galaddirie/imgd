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
            <p class="text-sm font-semibold text-base-content">Manual Run Input</p>
            <p class="text-xs text-base-content/60">
              Provide JSON for your trigger payload or load one of the demo presets.
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
          <div class="xl:col-span-2 space-y-2">
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
              <span>Blank value sends an empty map. Scalars are supported (e.g. 42, "hello").</span>
              <span :if={@run_form_error} class="text-error font-medium">
                {@run_form_error}
              </span>
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
              Payload is passed to the first node as trigger input. Use numbers, strings, objects, or arrays.
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
              Publish the workflow to enable runs.
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

  def dag_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 overflow-hidden">
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-squares-2x2" class="size-4 opacity-70" /> Workflow Graph
        </h2>
        <span class="text-xs text-base-content/60">
          {length(@workflow.nodes || [])} nodes
        </span>
      </div>

      <div class="p-4 overflow-auto bg-base-200/30" style="max-height: 600px;">
        <%= if @workflow.nodes == [] or is_nil(@workflow.nodes) do %>
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
            <%!-- Edges --%>
            <g class="edges">
              <%= for edge <- @edges do %>
                <path
                  d={edge.path}
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  class="text-base-300"
                  marker-end="url(#arrowhead)"
                />
              <% end %>
            </g>

            <%!-- Arrow marker definition --%>
            <defs>
              <marker
                id="arrowhead"
                markerWidth="10"
                markerHeight="7"
                refX="9"
                refY="3.5"
                orient="auto"
              >
                <polygon points="0 0, 10 3.5, 0 7" fill="currentColor" class="text-base-300" />
              </marker>
            </defs>

            <%!-- Nodes --%>
            <g class="nodes">
              <%= for node <- @workflow.nodes || [] do %>
                <% pos = Map.get(@layout, node.id, %{x: 0, y: 0}) %>
                <% state = Map.get(@node_states, node.id, %{}) %>
                <.dag_node
                  node={node}
                  position={pos}
                  state={state}
                  selected={@selected_node_id == node.id}
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
  # Component: DAG Node
  # ============================================================================

  attr :node, :map, required: true
  attr :position, :map, required: true
  attr :state, :map, required: true
  attr :selected, :boolean, default: false

  def dag_node(assigns) do
    ~H"""
    <g
      transform={"translate(#{@position.x}, #{@position.y})"}
      phx-click="select_node"
      phx-value-node-id={@node.id}
      class="cursor-pointer"
    >
      <%!-- Node background --%>
      <rect
        width="200"
        height="80"
        rx="12"
        class={[
          "transition-all duration-200",
          node_bg_class(@state[:status], @selected)
        ]}
        stroke-width={if @selected, do: "3", else: "1"}
      />

      <%!-- Status indicator --%>
      <circle
        cx="16"
        cy="16"
        r="6"
        class={node_status_indicator_class(@state[:status])}
      />

      <%!-- Running animation --%>
      <%= if @state[:status] == :running do %>
        <circle cx="16" cy="16" r="6" class="fill-info animate-ping opacity-50" />
      <% end %>

      <%!-- Node name --%>
      <text x="32" y="20" class="text-sm font-medium fill-current" dominant-baseline="middle">
        {truncate_text(@node.name, 20)}
      </text>

      <%!-- Node type --%>
      <text x="16" y="44" class="text-xs fill-current opacity-60">
        {node_type_label(@node.type_id)}
      </text>

      <%!-- Duration if completed --%>
      <%= if @state[:duration_ms] do %>
        <text x="16" y="64" class="text-xs fill-current opacity-50">
          {format_duration(@state[:duration_ms])}
        </text>
      <% end %>

      <%!-- Error indicator --%>
      <%= if @state[:status] == :failed do %>
        <g transform="translate(176, 8)">
          <circle cx="8" cy="8" r="8" class="fill-error" />
          <text x="8" y="12" text-anchor="middle" class="text-xs fill-error-content font-bold">
            !
          </text>
        </g>
      <% end %>
    </g>
    """
  end

  defp node_bg_class(nil, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(nil, true), do: "fill-base-100 stroke-primary"
  defp node_bg_class(:pending, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(:pending, true), do: "fill-base-100 stroke-primary"
  defp node_bg_class(:running, _), do: "fill-info/10 stroke-info"
  defp node_bg_class(:completed, false), do: "fill-success/10 stroke-success"
  defp node_bg_class(:completed, true), do: "fill-success/10 stroke-primary"
  defp node_bg_class(:failed, false), do: "fill-error/10 stroke-error"
  defp node_bg_class(:failed, true), do: "fill-error/10 stroke-primary"
  defp node_bg_class(_, false), do: "fill-base-100 stroke-base-300"
  defp node_bg_class(_, true), do: "fill-base-100 stroke-primary"

  defp node_status_indicator_class(nil), do: "fill-base-300"
  defp node_status_indicator_class(:pending), do: "fill-warning"
  defp node_status_indicator_class(:running), do: "fill-info"
  defp node_status_indicator_class(:completed), do: "fill-success"
  defp node_status_indicator_class(:failed), do: "fill-error"
  defp node_status_indicator_class(_), do: "fill-base-300"

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

  defp format_duration(nil), do: ""
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 2)}s"

  # ============================================================================
  # Component: Node Details Panel
  # ============================================================================

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

      <div class="p-4">
        <%= if @selected_node_id do %>
          <% node = Map.get(@node_map, @selected_node_id) %>
          <% state = Map.get(@node_states, @selected_node_id, %{}) %>

          <div class="space-y-4">
            <%!-- Node Info --%>
            <div>
              <h3 class="font-medium text-base-content">{node.name}</h3>
              <p class="text-xs text-base-content/60 mt-1">
                Type: {node_type_label(node.type_id)}
              </p>
              <p class="text-xs font-mono text-base-content/40 mt-1">
                {node.id}
              </p>
            </div>

            <%!-- Status --%>
            <%= if state[:status] do %>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-1">
                  Status
                </p>
                <span class={["badge badge-sm", node_status_badge_class(state[:status])]}>
                  {state[:status]}
                </span>
                <%= if state[:duration_ms] do %>
                  <span class="text-xs text-base-content/60 ml-2">
                    {format_duration(state[:duration_ms])}
                  </span>
                <% end %>
              </div>
            <% end %>

            <%!-- Input Data --%>
            <.data_section title="Input" data={state[:input_data]} />

            <%!-- Output Data --%>
            <.data_section title="Output" data={state[:output_data]} />

            <%!-- Error --%>
            <%= if state[:error] do %>
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-error mb-1">
                  Error
                </p>
                <pre class="text-xs bg-error/10 text-error p-2 rounded-lg overflow-auto max-h-32"><%=
                  inspect(state[:error], pretty: true)
                %></pre>
              </div>
            <% end %>

            <%!-- Config --%>
            <.data_section title="Configuration" data={node.config} />
          </div>
        <% else %>
          <div class="text-center py-8 text-base-content/60">
            <.icon name="hero-cursor-arrow-rays" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">Click a node to view details</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp node_status_badge_class(:pending), do: "badge-warning"
  defp node_status_badge_class(:running), do: "badge-info"
  defp node_status_badge_class(:completed), do: "badge-success"
  defp node_status_badge_class(:failed), do: "badge-error"
  defp node_status_badge_class(_), do: "badge-ghost"

  attr :title, :string, required: true
  attr :data, :any, default: nil

  defp data_section(assigns) do
    ~H"""
    <div :if={@data && @data != %{}}>
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-1">
        {@title}
      </p>
      <pre class="text-xs bg-base-200/60 p-2 rounded-lg overflow-auto max-h-40"><%=
        format_json_preview(@data)
      %></pre>
    </div>
    """
  end

  defp format_json_preview(data) when is_map(data) or is_list(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> truncate_json(json, 500)
      _ -> inspect(data, pretty: true, limit: 20)
    end
  end

  defp format_json_preview(data), do: inspect(data, pretty: true, limit: 20)

  defp truncate_json(json, max_len) when byte_size(json) > max_len do
    String.slice(json, 0, max_len) <> "\n... (truncated)"
  end

  defp truncate_json(json, _), do: json

  # ============================================================================
  # Component: Trace Log Panel
  # ============================================================================

  def trace_log_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-document-text" class="size-4 opacity-70" /> Trace Log
        </h2>
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
          class={["py-1 px-2 rounded", trace_log_entry_class(entry.level)]}
        >
          <span class="text-base-content/40">
            {format_log_timestamp(entry.timestamp)}
          </span>
          <span class={trace_log_level_class(entry.level)}>
            [{entry.level}]
          </span>
          <span class="text-base-content">
            {entry.message}
          </span>
          <%= if entry.data && entry.data != %{} do %>
            <span class="text-base-content/60 ml-1">
              {format_log_data(entry.data)}
            </span>
          <% end %>
        </div>

        <div
          :if={@trace_log_count == 0}
          class="text-center py-8 text-base-content/60"
        >
          <p class="text-sm">No log entries yet</p>
          <p class="text-xs mt-1">Run the workflow to see trace output</p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() {
            this.scrollToBottom()
            this.autoScroll = true

            // Track if user has scrolled up (disable auto-scroll)
            this.el.addEventListener('scroll', () => {
              const { scrollTop, scrollHeight, clientHeight } = this.el
              // Consider "at bottom" if within 50px of bottom
              this.autoScroll = scrollTop + clientHeight >= scrollHeight - 50
            })
          },

          updated() {
            if (this.autoScroll) {
              this.scrollToBottom()
            }
          },

          scrollToBottom() {
            // Use requestAnimationFrame to ensure DOM is updated
            requestAnimationFrame(() => {
              this.el.scrollTop = this.el.scrollHeight
            })
          }
        }
      </script>
    </div>
    """
  end

  defp trace_log_entry_class(:error), do: "bg-error/10"
  defp trace_log_entry_class(:success), do: "bg-success/10"
  defp trace_log_entry_class(_), do: "hover:bg-base-200/50"

  defp trace_log_level_class(:error), do: "text-error font-semibold"
  defp trace_log_level_class(:success), do: "text-success font-semibold"
  defp trace_log_level_class(:warning), do: "text-warning"
  defp trace_log_level_class(_), do: "text-info"

  defp format_log_timestamp(nil), do: "--:--:--"

  defp format_log_timestamp(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_log_data(data) when is_map(data) and map_size(data) == 0, do: ""

  defp format_log_data(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end

  defp format_log_data(_), do: ""

  # ============================================================================
  # Component: Execution Metadata Panel
  # ============================================================================

  def execution_metadata_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 mt-6">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-information-circle" class="size-4 opacity-70" /> Execution Details
        </h2>
      </div>

      <div class="p-4">
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <tbody>
              <tr class="hover">
                <td class="font-mono text-xs">{short_id(@execution.id)}</td>
                <td>
                  <span class={["badge badge-xs", execution_badge_class(@execution.status)]}>
                    {@execution.status}
                  </span>
                </td>
                <td class="text-xs text-base-content/60">
                  {formatted_timestamp(@execution.started_at)}
                </td>
                <td class="text-xs">
                  {format_duration(Execution.duration_ms(@execution))}
                </td>
                <td>
                  <.link
                    navigate={~p"/workflows/#{@execution.workflow_id}/executions/#{@execution.id}"}
                    class="btn btn-ghost btn-xs"
                    title="Inspect execution"
                  >
                    <.icon name="hero-eye" class="size-4" />
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%= if @execution.error do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-error mb-2">
              Error Details
            </p>
            <pre class="text-xs bg-error/10 text-error p-3 rounded-lg overflow-auto max-h-40"><%=
              inspect(@execution.error, pretty: true)
            %></pre>
          </div>
        <% end %>

        <%= if @execution.output && @execution.output != %{} do %>
          <div class="mt-4 pt-4 border-t border-base-200">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
              Output
            </p>
            <pre class="text-xs bg-base-200/60 p-3 rounded-lg overflow-auto max-h-40"><%=
              format_json_preview(@execution.output)
            %></pre>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
