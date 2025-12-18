defmodule ImgdWeb.WorkflowLive.NodeConfigModal do
  @moduledoc """
  Modal component for configuring node inputs with expression support.

  Features:
  - Toggle between literal values and expressions for any field
  - Live expression preview when upstream context is available
  - Pin output data for testing/development
  - Field validation with error display
  """
  use ImgdWeb, :live_component

  alias Imgd.Runtime.Expression

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:field_modes, %{})
     |> assign(:field_values, %{})
     |> assign(:expression_previews, %{})
     |> assign(:expression_errors, %{})
     |> assign(:active_tab, :config)
     |> assign(:pin_label, "")
     |> assign(:show_pin_form, false)
     |> assign(:variable_search, "")
     |> assign(:explorer_expanded, %{"json" => true, "nodes" => true, "variables" => true})}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if assign_changed?(assigns, :node) and assigns[:node] do
        init_field_state(socket, assigns.node)
      else
        socket
      end

    {:ok, socket}
  end

  defp assign_changed?(assigns, key) do
    Map.has_key?(assigns, key)
  end

  defp init_field_state(socket, node) do
    config = node.config || %{}

    # Determine which fields are expressions vs literals
    {modes, values} =
      Enum.reduce(config, {%{}, %{}}, fn {key, value}, {modes_acc, vals_acc} ->
        {mode, clean_value} = detect_field_mode(value)
        {Map.put(modes_acc, key, mode), Map.put(vals_acc, key, clean_value)}
      end)

    socket
    |> assign(:field_modes, modes)
    |> assign(:field_values, values)
    |> assign(:expression_previews, %{})
    |> assign(:expression_errors, %{})
    |> maybe_evaluate_expressions()
  end

  defp detect_field_mode(value) when is_binary(value) do
    if Expression.contains_expression?(value) do
      {:expression, value}
    else
      {:literal, value}
    end
  end

  defp detect_field_mode(value), do: {:literal, value}

  defp maybe_evaluate_expressions(socket) do
    if socket.assigns[:execution_context] do
      evaluate_all_expressions(socket)
    else
      socket
    end
  end

  defp evaluate_all_expressions(socket) do
    context = socket.assigns.execution_context
    modes = socket.assigns.field_modes
    values = socket.assigns.field_values

    {previews, errors} =
      Enum.reduce(modes, {%{}, %{}}, fn {field, mode}, {prev_acc, err_acc} ->
        if mode == :expression do
          expr = Map.get(values, field, "")

          case evaluate_expression(expr, context) do
            {:ok, result} ->
              {Map.put(prev_acc, field, result), err_acc}

            {:error, reason} ->
              {prev_acc, Map.put(err_acc, field, format_eval_error(reason))}
          end
        else
          {prev_acc, err_acc}
        end
      end)

    socket
    |> assign(:expression_previews, previews)
    |> assign(:expression_errors, errors)
  end

  defp evaluate_expression(expr, context) when is_binary(expr) and expr != "" do
    Expression.evaluate(expr, context)
  end

  defp evaluate_expression(_, _), do: {:ok, nil}

  defp format_eval_error(%{message: msg}), do: msg
  defp format_eval_error(reason) when is_binary(reason), do: reason
  defp format_eval_error(reason), do: inspect(reason)

  @impl true
  def handle_event("toggle_mode", %{"field" => field}, socket) do
    current_mode = Map.get(socket.assigns.field_modes, field, :literal)
    new_mode = if current_mode == :literal, do: :expression, else: :literal

    socket =
      socket
      |> assign(:field_modes, Map.put(socket.assigns.field_modes, field, new_mode))
      |> maybe_evaluate_expressions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    socket =
      socket
      |> assign(:field_values, Map.put(socket.assigns.field_values, field, value))
      |> maybe_evaluate_single_field(field)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("search_variables", %{"value" => search}, socket) do
    {:noreply, assign(socket, :variable_search, search)}
  end

  @impl true
  def handle_event("toggle_explorer_section", %{"section" => section}, socket) do
    expanded = socket.assigns.explorer_expanded
    new_expanded = Map.put(expanded, section, !Map.get(expanded, section, false))
    {:noreply, assign(socket, :explorer_expanded, new_expanded)}
  end

  @impl true
  def handle_event("toggle_pin_form", _, socket) do
    {:noreply, assign(socket, :show_pin_form, not socket.assigns.show_pin_form)}
  end

  @impl true
  def handle_event("update_pin_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, :pin_label, label)}
  end

  @impl true
  def handle_event("save_config", _, socket) do
    # Build the final config with expression markers
    config = build_final_config(socket)
    send(self(), {:node_config_saved, socket.assigns.node.id, config})
    {:noreply, socket}
  end

  @impl true
  def handle_event("pin_output", _, socket) do
    label = socket.assigns.pin_label
    node_id = socket.assigns.node.id
    output_data = socket.assigns[:node_output]

    send(self(), {:pin_node_output, node_id, output_data, label})
    {:noreply, assign(socket, :show_pin_form, false)}
  end

  @impl true
  def handle_event("close", _, socket) do
    send(self(), :close_node_config_modal)
    {:noreply, socket}
  end

  defp maybe_evaluate_single_field(socket, field) do
    mode = Map.get(socket.assigns.field_modes, field)

    if mode == :expression and socket.assigns[:execution_context] do
      value = Map.get(socket.assigns.field_values, field, "")

      case evaluate_expression(value, socket.assigns.execution_context) do
        {:ok, result} ->
          socket
          |> assign(
            :expression_previews,
            Map.put(socket.assigns.expression_previews, field, result)
          )
          |> assign(:expression_errors, Map.delete(socket.assigns.expression_errors, field))

        {:error, reason} ->
          socket
          |> assign(
            :expression_errors,
            Map.put(socket.assigns.expression_errors, field, format_eval_error(reason))
          )
          |> assign(:expression_previews, Map.delete(socket.assigns.expression_previews, field))
      end
    else
      socket
    end
  end

  defp build_final_config(socket) do
    values = socket.assigns.field_values

    Map.new(values, fn {field, value} ->
      {field, value}
    end)
  end

  # Get field schema for the node type
  defp get_field_schema(node) do
    # This would ideally come from a node type registry
    # For now, we'll infer from existing config
    config = node.config || %{}

    Enum.map(config, fn {key, value} ->
      %{
        key: key,
        label: humanize_key(key),
        type: infer_field_type(value),
        description: nil,
        required: false
      }
    end)
  end

  defp humanize_key(key) when is_atom(key), do: key |> Atom.to_string() |> humanize_key()

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp infer_field_type(value) when is_boolean(value), do: :boolean
  defp infer_field_type(value) when is_integer(value), do: :integer
  defp infer_field_type(value) when is_float(value), do: :number
  defp infer_field_type(value) when is_map(value), do: :json
  defp infer_field_type(value) when is_list(value), do: :json

  defp infer_field_type(value) when is_binary(value) do
    cond do
      String.length(value) > 100 -> :textarea
      String.contains?(value, "\n") -> :textarea
      true -> :text
    end
  end

  defp infer_field_type(_), do: :text

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 sm:p-6"
      phx-window-keydown="close"
      phx-key="escape"
      phx-target={@myself}
    >
      <div
        class="bg-base-100 rounded-3xl shadow-2xl w-full max-w-7xl h-[90vh] flex flex-col overflow-hidden border border-base-300 transition-all duration-300"
        phx-click-away="close"
        phx-target={@myself}
      >
        <%!-- Header --%>
        <div class="px-6 py-4 border-b border-base-200 flex items-center justify-between bg-base-200/40">
          <div class="flex items-center gap-4">
            <div class="flex items-center justify-center w-12 h-12 rounded-2xl bg-primary/10 text-primary shadow-inner">
              <.icon name="hero-cube" class="size-6" />
            </div>
            <div>
              <div class="flex items-center gap-2">
                <h2 class="text-lg font-bold text-base-content leading-none">{@node.name}</h2>
                <span class="badge badge-primary badge-sm font-mono opacity-80">
                  {short_id(@node.id)}
                </span>
              </div>
              <p class="text-xs text-base-content/50 mt-1 font-medium flex items-center gap-1.5">
                <span class="size-1.5 rounded-full bg-success"></span>
                {node_type_label(@node.type_id)} Node
              </p>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <div class="flex bg-base-300/50 p-1 rounded-xl">
              <button
                type="button"
                class={[
                  "px-4 py-2 text-xs font-bold rounded-lg transition-all",
                  @active_tab == :config && "bg-base-100 text-primary shadow-sm",
                  @active_tab != :config && "text-base-content/60 hover:text-base-content"
                ]}
                phx-click="switch_tab"
                phx-value-tab="config"
                phx-target={@myself}
              >
                Parameters
              </button>
              <button
                type="button"
                class={[
                  "px-4 py-2 text-xs font-bold rounded-lg transition-all",
                  @active_tab == :output && "bg-base-100 text-primary shadow-sm",
                  @active_tab != :output && "text-base-content/60 hover:text-base-content"
                ]}
                phx-click="switch_tab"
                phx-value-tab="output"
                phx-target={@myself}
              >
                Output
              </button>
              <button
                type="button"
                class={[
                  "px-4 py-2 text-xs font-bold rounded-lg transition-all",
                  @active_tab == :pinned && "bg-base-100 text-primary shadow-sm",
                  @active_tab != :pinned && "text-base-content/60 hover:text-base-content"
                ]}
                phx-click="switch_tab"
                phx-value-tab="pinned"
                phx-target={@myself}
              >
                Pinned
              </button>
            </div>

            <button
              type="button"
              class="btn btn-ghost btn-sm btn-circle hover:bg-error/10 hover:text-error transition-colors ml-4"
              phx-click="close"
              phx-target={@myself}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
        </div>

        <%!-- Main content: Split Layout --%>
        <div class="flex-1 flex overflow-hidden bg-base-200/20">
          <%!-- Left: Variable Explorer (Context) --%>
          <div class="w-80 border-r border-base-200 bg-base-100/50 flex flex-col overflow-hidden">
            <div class="p-4 border-b border-base-200 bg-base-200/10">
              <div class="relative">
                <.icon
                  name="hero-magnifying-glass"
                  class="size-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                />
                <input
                  type="text"
                  placeholder="Search variables..."
                  class="input input-sm input-bordered w-full pl-9 bg-base-100 border-base-300 focus:border-primary text-xs font-medium"
                  phx-keyup="search_variables"
                  phx-target={@myself}
                  value={@variable_search}
                />
              </div>
            </div>
            <div class="flex-1 overflow-y-auto custom-scrollbar">
              <.variable_explorer
                context={@execution_context}
                search={@variable_search}
                expanded={@explorer_expanded}
                myself={@myself}
              />
            </div>
            <div class="p-4 border-t border-base-200 bg-base-200/5">
              <div class="text-[10px] font-bold uppercase tracking-wider text-base-content/40 mb-2">
                Expression Tip
              </div>
              <p class="text-[11px] text-base-content/60 leading-relaxed">
                Click any variable to copy its Liquid expression to your clipboard.
              </p>
            </div>
          </div>

          <%!-- Right: Tab Content (Config / Output) --%>
          <div class="flex-1 overflow-y-auto p-8 custom-scrollbar relative">
            <%= case @active_tab do %>
              <% :config -> %>
                <.config_tab
                  node={@node}
                  field_modes={@field_modes}
                  field_values={@field_values}
                  expression_previews={@expression_previews}
                  expression_errors={@expression_errors}
                  has_context={not is_nil(@execution_context)}
                  myself={@myself}
                />
              <% :output -> %>
                <.output_tab
                  node_output={@node_output}
                  show_pin_form={@show_pin_form}
                  pin_label={@pin_label}
                  myself={@myself}
                />
              <% :pinned -> %>
                <.pinned_tab
                  pinned_data={@pinned_data}
                  node_id={@node.id}
                />
            <% end %>
          </div>
        </div>

        <%!-- Footer --%>
        <div class="px-8 py-5 border-t border-base-200 flex items-center justify-between bg-base-100">
          <div class="flex items-center gap-6">
            <div class="flex items-center gap-2">
              <div class={[
                "size-2 rounded-full",
                if(@execution_context, do: "bg-success animate-pulse", else: "bg-warning")
              ]}>
              </div>
              <span class="text-xs font-bold text-base-content/70">
                {if @execution_context, do: "Live Preview Active", else: "Static Mode"}
              </span>
            </div>
            <%= if !@execution_context do %>
              <div class="flex items-center gap-1.5 text-xs text-base-content/40 font-medium">
                <.icon name="hero-information-circle" class="size-4" />
                Run workflow to enable expression previews
              </div>
            <% end %>
          </div>

          <div class="flex items-center gap-4">
            <button
              type="button"
              class="btn btn-ghost btn-sm font-bold text-base-content/60 hover:text-base-content"
              phx-click="close"
              phx-target={@myself}
            >
              Discard Changes
            </button>
            <button
              type="button"
              class="btn btn-primary px-8 rounded-xl font-bold shadow-lg shadow-primary/20 hover:shadow-primary/30 active:scale-95 transition-all"
              phx-click="save_config"
              phx-target={@myself}
            >
              Save Configuration
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Sub-components
  # ============================================================================

  attr :context, :map, required: true
  attr :search, :string, default: ""
  attr :expanded, :map, required: true
  attr :myself, :any, required: true

  defp variable_explorer(assigns) do
    # Transform execution context struct to map with string keys for explorer
    context_map =
      if assigns.context do
        Imgd.Runtime.Expression.Context.build(assigns.context)
      else
        nil
      end

    sections = [
      %{
        id: "json",
        label: "Current Input",
        icon: "hero-arrow-right-on-rectangle",
        data: context_map && context_map["json"]
      },
      %{
        id: "nodes",
        label: "Upstream Nodes",
        icon: "hero-cpu-chip",
        data: context_map && context_map["nodes"]
      },
      %{
        id: "variables",
        label: "Workflow Variables",
        icon: "hero-variable",
        data: context_map && context_map["variables"]
      },
      %{
        id: "execution",
        label: "Execution Metadata",
        icon: "hero-identification",
        data: context_map && context_map["execution"]
      },
      %{
        id: "system",
        label: "System",
        icon: "hero-globe-alt",
        data:
          context_map &&
            %{
              "now" => context_map["now"],
              "today" => context_map["today"],
              "env" => context_map["env"]
            }
      }
    ]

    assigns = assigns |> assign(:sections, sections) |> assign(:context_map, context_map)

    ~H"""
    <div class="p-2 space-y-1">
      <%= for section <- @sections do %>
        <div class="overflow-hidden">
          <button
            type="button"
            class={[
              "w-full flex items-center justify-between p-2 rounded-xl text-xs font-bold transition-all",
              "hover:bg-primary/5 group",
              @expanded[section.id] && "text-primary bg-primary/5",
              !@expanded[section.id] && "text-base-content/60"
            ]}
            phx-click="toggle_explorer_section"
            phx-value-section={section.id}
            phx-target={@myself}
          >
            <div class="flex items-center gap-2">
              <.icon name={section.icon} class="size-4 opacity-70 group-hover:opacity-100" />
              {section.label}
            </div>
            <.icon
              name={if @expanded[section.id], do: "hero-chevron-down", else: "hero-chevron-right"}
              class="size-3 opacity-40"
            />
          </button>

          <%= if @expanded[section.id] do %>
            <div class="mt-1 ml-4 pl-2 border-l border-base-200 py-1 space-y-0.5">
              <%= if is_nil(section.data) or section.data == %{} do %>
                <div class="p-2 text-[10px] text-base-content/40 italic">No data available</div>
              <% else %>
                <.tree_node
                  data={section.data}
                  path={if section.id == "system", do: "", else: section.id}
                  search={@search}
                  level={0}
                />
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp tree_node(assigns) do
    data = assigns.data
    search = assigns.search |> String.downcase()

    # Filter data if search is present
    filtered_data =
      if search == "" do
        data
      else
        filter_tree(data, search)
      end

    assigns = assign(assigns, :filtered_data, filtered_data)

    ~H"""
    <div class="space-y-0.5">
      <%= for {key, value} <- sort_keys(@filtered_data) do %>
        <% current_path = if @path == "", do: key, else: "#{@path}.#{key}" %>
        <% full_expr = "{{ #{current_path} }}" %>

        <%= if is_map(value) and value != %{} do %>
          <details class="group/node">
            <summary class="flex items-center gap-1.5 p-1.5 rounded-lg hover:bg-base-200 cursor-pointer transition-colors list-none">
              <.icon
                name="hero-chevron-right"
                class="size-3 opacity-30 group-open/node:rotate-90 transition-transform"
              />
              <span class="text-[11px] font-mono text-base-content/70">{key}</span>
              <span class="text-[9px] text-base-content/30 italic">Map</span>
            </summary>
            <div class="ml-3 pl-2 border-l border-base-200/50 mt-0.5">
              <.tree_node data={value} path={current_path} search={@search} level={@level + 1} />
            </div>
          </details>
        <% else %>
          <div
            class="group/item flex items-center justify-between p-1.5 rounded-lg hover:bg-primary/10 hover:text-primary cursor-pointer transition-all"
            title={"Click to copy: #{full_expr}"}
            data-expr={full_expr}
            onclick="navigator.clipboard.writeText(this.getAttribute('data-expr'))"
          >
            <div class="flex items-center gap-2 overflow-hidden">
              <.icon name="hero-variable" class="size-3 opacity-30 group-hover/item:opacity-100" />
              <span class="text-[11px] font-mono truncate">{key}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-[10px] text-base-content/40 truncate max-w-[100px] font-medium">
                {format_short_value(value)}
              </span>
              <.icon name="hero-square-2-stack" class="size-3 opacity-0 group-hover/item:opacity-50" />
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp filter_tree(data, search) when is_map(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      k_str = to_string(k) |> String.downcase()

      cond do
        String.contains?(k_str, search) ->
          Map.put(acc, k, v)

        is_map(v) ->
          filtered_v = filter_tree(v, search)
          if filtered_v != %{}, do: Map.put(acc, k, filtered_v), else: acc

        true ->
          acc
      end
    end)
  end

  defp filter_tree(data, _), do: data

  defp sort_keys(data) when is_map(data), do: Enum.sort_by(data, fn {k, _} -> to_string(k) end)
  defp sort_keys(data), do: data

  defp format_short_value(nil), do: "null"

  defp format_short_value(v) when is_binary(v),
    do: "\"#{String.slice(v, 0, 20)}#{if byte_size(v) > 20, do: "...", else: ""}\""

  defp format_short_value(v) when is_boolean(v), do: to_string(v)
  defp format_short_value(v) when is_number(v), do: to_string(v)
  defp format_short_value(_), do: "..."

  attr :node, :map, required: true
  attr :field_modes, :map, required: true
  attr :field_values, :map, required: true
  attr :expression_previews, :map, required: true
  attr :expression_errors, :map, required: true
  attr :has_context, :boolean, required: true
  attr :myself, :any, required: true

  defp config_tab(assigns) do
    fields = get_field_schema(assigns.node)
    assigns = assign(assigns, :fields, fields)

    ~H"""
    <div class="max-w-3xl mx-auto space-y-12 pb-20">
      <div class="space-y-1">
        <h3 class="text-lg font-semibold text-base-content tracking-tight">Node Configuration</h3>
        <p class="text-xs text-base-content/50 font-medium">
          Configure the parameters for this {@node.type_id} operation.
        </p>
      </div>

      <%!-- Fields --%>
      <%= if @fields == [] do %>
        <div class="flex flex-col items-center justify-center py-20 bg-base-300/10 rounded-3xl border-2 border-dashed border-base-300">
          <div class="size-16 rounded-2xl bg-base-300/30 flex items-center justify-center mb-4">
            <.icon name="hero-cog-6-tooth" class="size-8 text-base-content/20" />
          </div>
          <p class="text-xs font-bold text-base-content/40">No configurable fields available</p>
        </div>
      <% else %>
        <div class="space-y-6">
          <%= for field <- @fields do %>
            <.config_field
              field={field}
              mode={Map.get(@field_modes, field.key, :literal)}
              value={Map.get(@field_values, field.key, "")}
              preview={Map.get(@expression_previews, field.key)}
              error={Map.get(@expression_errors, field.key)}
              has_context={@has_context}
              myself={@myself}
            />
          <% end %>
        </div>
      <% end %>

      <%!-- Help --%>
      <div class="p-5 rounded-2xl bg-primary/5 border border-primary/10">
        <div class="flex items-start gap-3">
          <div class="size-8 rounded-lg bg-primary/10 flex items-center justify-center shrink-0">
            <.icon name="hero-light-bulb" class="size-4 text-primary" />
          </div>
          <div>
            <h4 class="text-xs font-bold text-primary mb-1">Using Expressions</h4>
            <p class="text-[11px] text-base-content/60 leading-relaxed">
              Switch any field to <span class="font-bold text-secondary">Expression Mode</span>
              to use dynamic data from upstream nodes. Use the sidebar to find and copy variable paths.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :mode, :atom, required: true
  attr :value, :any, required: true
  attr :preview, :any, default: nil
  attr :error, :string, default: nil
  attr :has_context, :boolean, required: true
  attr :myself, :any, required: true

  defp config_field(assigns) do
    ~H"""
    <div class="group relative">
      <div class={[
        "rounded-2xl border transition-all duration-300",
        @mode == :literal && "border-base-300 bg-base-100 shadow-sm",
        @mode == :expression && "border-secondary/20 bg-secondary/[0.02] shadow-inner"
      ]}>
        <%!-- Field Header --%>
        <div class="px-5 py-3 border-b border-base-200/50 flex items-center justify-between">
          <div>
            <label class="block text-sm font-medium text-base-content tracking-tight">
              {@field.label}
            </label>
            <p :if={@field.description} class="text-[10px] text-base-content/40 font-medium mt-0.5">
              {@field.description}
            </p>
          </div>

          <%!-- Mode Toggle --%>
          <div class="join">
            <button
              type="button"
              class={[
                "join-item btn btn-xs",
                @mode == :literal && "btn-primary",
                @mode != :literal && "btn-ghost"
              ]}
              phx-click="toggle_mode"
              phx-value-field={@field.key}
              phx-target={@myself}
            >
              <.icon name="hero-pencil" class="size-3" /> Fixed
            </button>
            <button
              type="button"
              class={[
                "join-item btn btn-xs",
                @mode == :expression && "btn-secondary",
                @mode != :expression && "btn-ghost"
              ]}
              phx-click="toggle_mode"
              phx-value-field={@field.key}
              phx-target={@myself}
            >
              <.icon name="hero-code-bracket" class="size-3" /> Expression
            </button>
          </div>
        </div>

        <%!-- Field Input --%>
        <div class="p-5">
          <%= if @mode == :literal do %>
            <.literal_input field={@field} value={@value} myself={@myself} />
          <% else %>
            <.expression_input
              field={@field}
              value={@value}
              preview={@preview}
              error={@error}
              has_context={@has_context}
              myself={@myself}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  defp literal_input(assigns) do
    ~H"""
    <div class="w-full">
      <%= case @field.type do %>
        <% :boolean -> %>
          <div class="flex items-center justify-between bg-base-200/20 p-3 rounded-xl border border-base-200/50">
            <span class="text-xs font-medium text-base-content/60">
              {if @value == true or @value == "true", do: "Enabled", else: "Disabled"}
            </span>
            <input
              type="checkbox"
              class="toggle toggle-primary toggle-md"
              checked={@value == true or @value == "true"}
              phx-click="update_field"
              phx-value-field={@field.key}
              phx-value-value={if @value, do: "false", else: "true"}
              phx-target={@myself}
            />
          </div>
        <% :integer -> %>
          <input
            type="number"
            class="input input-md w-full bg-base-200/20 border-base-300 focus:border-primary font-medium text-sm rounded-xl"
            value={@value}
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          />
        <% :number -> %>
          <input
            type="number"
            step="any"
            class="input input-md w-full bg-base-200/20 border-base-300 focus:border-primary font-medium text-sm rounded-xl"
            value={@value}
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          />
        <% :textarea -> %>
          <textarea
            class="textarea textarea-bordered w-full font-mono text-xs bg-base-200/10 border-base-300 focus:border-primary min-h-[100px] leading-relaxed rounded-xl"
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          >{@value}</textarea>
        <% :json -> %>
          <div class="relative group/json">
            <textarea
              class="textarea textarea-bordered w-full font-mono text-[11px] bg-base-200/10 border-base-300 focus:border-primary min-h-[180px] leading-relaxed scrollbar-hide rounded-xl"
              spellcheck="false"
              phx-blur="update_field"
              phx-value-field={@field.key}
              phx-target={@myself}
            >{format_json(@value)}</textarea>
          </div>
        <% _ -> %>
          <input
            type="text"
            class="input input-md w-full bg-base-200/20 border-base-300 focus:border-primary font-medium text-sm rounded-xl"
            value={@value}
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          />
      <% end %>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :value, :any, required: true
  attr :preview, :any, default: nil
  attr :error, :string, default: nil
  attr :has_context, :boolean, required: true
  attr :myself, :any, required: true

  defp expression_input(assigns) do
    ~H"""
    <div class="space-y-3">
      <%!-- Expression Editor --%>
      <div class="relative group/expr">
        <div class="absolute left-4 top-3 text-secondary/30 group-focus-within/expr:text-secondary group-focus-within/expr:scale-110 transition-all duration-300">
          <.icon name="hero-code-bracket" class="size-5" />
        </div>
        <textarea
          class={[
            "textarea w-full font-mono text-[13px] pl-12 pr-10 py-3 bg-base-100 border-2 transition-all duration-300 min-h-[80px] leading-relaxed rounded-xl",
            "border-secondary/10 focus:border-secondary/40 focus:ring-4 focus:ring-secondary/5",
            @error && "border-error/30 focus:border-error/60 focus:ring-error/5"
          ]}
          spellcheck="false"
          placeholder="{{ nodes.PreviousNode.json.field }}"
          phx-keyup="update_field"
          phx-blur="update_field"
          phx-debounce="300"
          phx-value-field={@field.key}
          phx-target={@myself}
        >{@value}</textarea>
      </div>

      <%!-- Preview Result --%>
      <div class="overflow-hidden rounded-xl border border-base-200/60 bg-base-200/20">
        <div class="flex items-center justify-between px-4 py-1.5 border-b border-base-200/40 bg-base-200/30">
          <span class="text-[9px] font-bold uppercase tracking-widest text-base-content/30">
            Live Preview
          </span>
          <%= cond do %>
            <% @error -> %>
              <span class="text-[9px] font-bold text-error uppercase">Error</span>
            <% @has_context and @preview != nil -> %>
              <span class="text-[9px] font-bold text-success uppercase">Success</span>
            <% @has_context -> %>
              <span class="text-[9px] font-bold text-base-content/20 uppercase">Empty</span>
            <% true -> %>
              <span class="text-[9px] font-bold text-warning uppercase tracking-tighter">
                Context Missing
              </span>
          <% end %>
        </div>

        <div class="p-3">
          <%= cond do %>
            <% @error -> %>
              <div class="flex gap-2 text-error/80">
                <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0 mt-0.5" />
                <p class="text-[10px] font-mono leading-relaxed">{@error}</p>
              </div>
            <% @has_context and @preview != nil -> %>
              <pre class="text-[11px] text-base-content/70 font-mono overflow-auto max-h-32 leading-relaxed custom-scrollbar">{format_preview(@preview)}</pre>
            <% @has_context -> %>
              <p class="text-[10px] text-base-content/20 italic font-medium">No output generated.</p>
            <% true -> %>
              <p class="text-[10px] text-base-content/40 font-medium leading-relaxed">
                Run workflow to see live preview.
              </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :node_output, :any, default: nil
  attr :show_pin_form, :boolean, default: false
  attr :pin_label, :string, default: ""
  attr :myself, :any, required: true

  defp output_tab(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-8 pb-20">
      <div class="flex items-center justify-between">
        <div class="space-y-1">
          <h3 class="text-xl font-bold text-base-content tracking-tight">Execution Output</h3>
          <p class="text-sm text-base-content/50 font-medium">
            Data captured from the last time this node was executed.
          </p>
        </div>
        <%= if @node_output do %>
          <button
            type="button"
            class={[
              "btn gap-2 rounded-xl transition-all font-bold shadow-sm",
              @show_pin_form && "btn-ghost text-base-content/40",
              !@show_pin_form && "btn-outline btn-primary shadow-primary/5"
            ]}
            phx-click="toggle_pin_form"
            phx-target={@myself}
          >
            <.icon name={if @show_pin_form, do: "hero-x-mark", else: "hero-bookmark"} class="size-4" />
            {if @show_pin_form, do: "Cancel Pinning", else: "Pin this result"}
          </button>
        <% end %>
      </div>

      <%= if @node_output do %>
        <%!-- Pin Form --%>
        <div
          :if={@show_pin_form}
          class="rounded-3xl bg-primary/5 border-2 border-primary/10 p-8 shadow-inner animate-in fade-in slide-in-from-top-4"
        >
          <div class="flex flex-col sm:flex-row items-end gap-4">
            <div class="flex-1 w-full">
              <label class="block text-xs font-bold uppercase tracking-widest text-primary/60 mb-2 ml-1">
                Pin Label (Optional)
              </label>
              <input
                type="text"
                class="input input-bordered w-full bg-base-100 border-primary/20 focus:border-primary font-bold rounded-xl"
                placeholder="e.g., Sample API Success Response"
                value={@pin_label}
                phx-blur="update_pin_label"
                phx-target={@myself}
              />
            </div>
            <button
              type="button"
              class="btn btn-primary px-8 rounded-xl font-bold shadow-lg shadow-primary/20 w-full sm:w-auto"
              phx-click="pin_output"
              phx-target={@myself}
            >
              Confirm Pin
            </button>
          </div>
          <p class="text-[11px] text-primary/40 font-bold uppercase tracking-wider mt-4 text-center">
            Pinned data will be used instead of re-executing this node during tests.
          </p>
        </div>

        <div class="relative group">
          <div class="absolute top-4 right-4 z-10 opacity-0 group-hover:opacity-100 transition-opacity">
            <button
              class="btn btn-xs btn-neutral font-bold rounded-lg"
              onclick="navigator.clipboard.writeText(document.getElementById('output-code').innerText)"
            >
              Copy JSON
            </button>
          </div>
          <pre
            id="output-code"
            class="text-xs font-mono bg-base-300/20 p-8 rounded-3xl overflow-auto max-h-[500px] border border-base-200 leading-relaxed scrollbar-hide"
          >{format_json(@node_output)}</pre>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-32 bg-base-200/20 rounded-[40px] border-2 border-dashed border-base-300">
          <div class="size-20 rounded-3xl bg-base-300/30 flex items-center justify-center mb-6">
            <.icon name="hero-arrow-path" class="size-10 text-base-content/10" />
          </div>
          <h4 class="text-lg font-bold text-base-content/40">No Output Available</h4>
          <p class="text-sm text-base-content/30 font-medium mt-1">
            Run the workflow to capture this node's output.
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  attr :pinned_data, :map, default: nil
  attr :node_id, :string, required: true

  defp pinned_tab(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-8 pb-20">
      <div class="space-y-1">
        <h3 class="text-xl font-bold text-base-content tracking-tight">Pinned Data</h3>
        <p class="text-sm text-base-content/50 font-medium">
          Reusable snapshots for consistent testing and development.
        </p>
      </div>

      <%= if @pinned_data do %>
        <%!-- Pin Info Card --%>
        <div class="relative overflow-hidden rounded-[32px] bg-primary/5 border-2 border-primary/10 p-8 shadow-sm">
          <div class="absolute top-0 right-0 p-4">
            <button
              type="button"
              class="btn btn-ghost btn-sm text-error font-bold hover:bg-error/10 rounded-xl"
              phx-click="clear_pin"
              phx-value-node-id={@node_id}
            >
              <.icon name="hero-trash" class="size-4" /> Remove Pin
            </button>
          </div>

          <div class="flex items-start gap-6">
            <div class="size-16 rounded-2xl bg-primary/10 flex items-center justify-center shrink-0 shadow-inner">
              <.icon name="hero-bookmark-solid" class="size-8 text-primary" />
            </div>
            <div>
              <h4 class="text-lg font-bold text-primary mb-1 leading-none">
                {@pinned_data["label"] || "Untitled Pin"}
              </h4>
              <p class="text-xs text-primary/40 font-bold uppercase tracking-widest mt-2">
                Created {format_relative_time(@pinned_data["pinned_at"])}
              </p>
            </div>
          </div>

          <%= if @pinned_data["stale"] do %>
            <div class="mt-8 p-4 rounded-2xl bg-warning/10 border border-warning/20 flex items-center gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
              <div class="text-xs font-bold text-warning/80">
                This pin is stale. The node configuration has changed since it was created.
              </div>
            </div>
          <% end %>
        </div>

        <div class="space-y-4">
          <div class="flex items-center gap-2 px-1">
            <.icon name="hero-document-text" class="size-4 text-base-content/40" />
            <span class="text-[10px] font-bold uppercase tracking-[0.2em] text-base-content/40">
              Data Snapshot
            </span>
          </div>
          <pre class="text-xs font-mono bg-base-300/20 p-8 rounded-[32px] overflow-auto max-h-[500px] border border-base-200 leading-relaxed scrollbar-hide">{format_json(@pinned_data["data"])}</pre>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-32 bg-base-200/20 rounded-[40px] border-2 border-dashed border-base-300">
          <div class="size-20 rounded-3xl bg-base-300/30 flex items-center justify-center mb-6">
            <.icon name="hero-bookmark" class="size-10 text-base-content/10" />
          </div>
          <h4 class="text-lg font-bold text-base-content/40">No Pinned Data</h4>
          <p class="text-sm text-base-content/30 font-medium mt-1">
            Pin an output to use it as a persistent mock for testing.
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp node_type_label(type_id) do
    type_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp short_id(id), do: String.slice(id, 0, 8)

  defp format_json(nil), do: "null"
  defp format_json(data) when is_binary(data), do: data

  defp format_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  defp format_preview(nil), do: "null"
  defp format_preview(data) when is_binary(data), do: data

  defp format_preview(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> truncate(json, 500)
      _ -> inspect(data, pretty: true, limit: 20)
    end
  end

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "\n... (truncated)"
  end

  defp truncate(str, _), do: str

  defp format_relative_time(nil), do: "unknown"

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
