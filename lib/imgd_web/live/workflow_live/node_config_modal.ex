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
     |> assign(:show_pin_form, false)}
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
          |> assign(:expression_previews, Map.put(socket.assigns.expression_previews, field, result))
          |> assign(:expression_errors, Map.delete(socket.assigns.expression_errors, field))
        {:error, reason} ->
          socket
          |> assign(:expression_errors, Map.put(socket.assigns.expression_errors, field, format_eval_error(reason)))
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
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      phx-window-keydown="close"
      phx-key="escape"
      phx-target={@myself}
    >
      <div
        class="bg-base-100 rounded-2xl shadow-2xl w-full max-w-4xl max-h-[90vh] flex flex-col overflow-hidden border border-base-300"
        phx-click-away="close"
        phx-target={@myself}
      >
        <%!-- Header --%>
        <div class="px-6 py-4 border-b border-base-200 flex items-center justify-between bg-base-200/30">
          <div class="flex items-center gap-4">
            <div class="flex items-center justify-center w-12 h-12 rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-cube" class="size-6" />
            </div>
            <div>
              <h2 class="text-lg font-semibold text-base-content">{@node.name}</h2>
              <p class="text-sm text-base-content/60 flex items-center gap-2">
                <span class="badge badge-ghost badge-sm">{node_type_label(@node.type_id)}</span>
                <span class="font-mono text-xs opacity-50">{short_id(@node.id)}</span>
              </p>
            </div>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="close"
            phx-target={@myself}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%!-- Tabs --%>
        <div class="border-b border-base-200 px-6">
          <div class="flex gap-1">
            <button
              type="button"
              class={[
                "px-4 py-3 text-sm font-medium border-b-2 transition-colors",
                @active_tab == :config && "border-primary text-primary",
                @active_tab != :config && "border-transparent text-base-content/60 hover:text-base-content"
              ]}
              phx-click="switch_tab"
              phx-value-tab="config"
              phx-target={@myself}
            >
              <.icon name="hero-cog-6-tooth" class="size-4 inline mr-1.5" />
              Configuration
            </button>
            <button
              type="button"
              class={[
                "px-4 py-3 text-sm font-medium border-b-2 transition-colors",
                @active_tab == :output && "border-primary text-primary",
                @active_tab != :output && "border-transparent text-base-content/60 hover:text-base-content"
              ]}
              phx-click="switch_tab"
              phx-value-tab="output"
              phx-target={@myself}
            >
              <.icon name="hero-arrow-up-on-square" class="size-4 inline mr-1.5" />
              Output
              <%= if @node_output do %>
                <span class="badge badge-success badge-xs ml-1">Available</span>
              <% end %>
            </button>
            <button
              type="button"
              class={[
                "px-4 py-3 text-sm font-medium border-b-2 transition-colors",
                @active_tab == :pinned && "border-primary text-primary",
                @active_tab != :pinned && "border-transparent text-base-content/60 hover:text-base-content"
              ]}
              phx-click="switch_tab"
              phx-value-tab="pinned"
              phx-target={@myself}
            >
              <.icon name="hero-bookmark" class="size-4 inline mr-1.5" />
              Pinned Data
              <%= if @pinned_data do %>
                <span class="badge badge-primary badge-xs ml-1">Pinned</span>
              <% end %>
            </button>
          </div>
        </div>

        <%!-- Body --%>
        <div class="flex-1 overflow-y-auto p-6">
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

        <%!-- Footer --%>
        <div class="px-6 py-4 border-t border-base-200 flex items-center justify-between bg-base-200/20">
          <div class="flex items-center gap-2 text-xs text-base-content/60">
            <%= if @execution_context do %>
              <span class="flex items-center gap-1 text-success">
                <.icon name="hero-check-circle" class="size-4" />
                Context available for previews
              </span>
            <% else %>
              <span class="flex items-center gap-1 text-warning">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                Run workflow to enable expression previews
              </span>
            <% end %>
          </div>
          <div class="flex items-center gap-3">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="close"
              phx-target={@myself}
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-primary gap-2"
              phx-click="save_config"
              phx-target={@myself}
            >
              <.icon name="hero-check" class="size-4" />
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
    <div class="space-y-6">
      <%!-- Context indicator --%>
      <div class={[
        "rounded-xl p-4 flex items-start gap-3",
        @has_context && "bg-success/10 border border-success/20",
        not @has_context && "bg-warning/10 border border-warning/20"
      ]}>
        <.icon
          name={if @has_context, do: "hero-check-circle", else: "hero-information-circle"}
          class={["size-5 mt-0.5", @has_context && "text-success", not @has_context && "text-warning"]}
        />
        <div>
          <p class={["font-medium text-sm", @has_context && "text-success", not @has_context && "text-warning"]}>
            {if @has_context, do: "Expression Preview Available", else: "Expression Preview Unavailable"}
          </p>
          <p class="text-xs text-base-content/60 mt-1">
            {if @has_context,
              do: "Upstream node outputs are available. Expression results will be previewed in real-time.",
              else: "Run the workflow first to populate upstream node outputs for expression previews."}
          </p>
        </div>
      </div>

      <%!-- Fields --%>
      <%= if @fields == [] do %>
        <div class="text-center py-12 text-base-content/60">
          <.icon name="hero-cog-6-tooth" class="size-12 mx-auto mb-3 opacity-30" />
          <p class="text-sm">This node has no configurable fields</p>
        </div>
      <% else %>
        <div class="space-y-4">
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

      <%!-- Expression Help --%>
      <details class="collapse collapse-arrow bg-base-200/50 rounded-xl">
        <summary class="collapse-title text-sm font-medium">
          <.icon name="hero-light-bulb" class="size-4 inline mr-2 text-warning" />
          Expression Syntax Help
        </summary>
        <div class="collapse-content text-sm">
          <div class="grid grid-cols-2 gap-4 pt-2">
            <div>
              <p class="font-semibold text-base-content mb-2">Available Variables</p>
              <ul class="space-y-1 text-base-content/70 text-xs font-mono">
                <li><code class="bg-base-300 px-1 rounded">{"{{ json }}"}</code> - Current input</li>
                <li><code class="bg-base-300 px-1 rounded">{"{{ nodes.NodeName.json }}"}</code> - Node output</li>
                <li><code class="bg-base-300 px-1 rounded">{"{{ execution.id }}"}</code> - Execution ID</li>
                <li><code class="bg-base-300 px-1 rounded">{"{{ variables.name }}"}</code> - Workflow var</li>
              </ul>
            </div>
            <div>
              <p class="font-semibold text-base-content mb-2">Common Filters</p>
              <ul class="space-y-1 text-base-content/70 text-xs font-mono">
                <li><code class="bg-base-300 px-1 rounded">| json</code> - Encode as JSON</li>
                <li><code class="bg-base-300 px-1 rounded">| dig: "a.b.c"</code> - Deep access</li>
                <li><code class="bg-base-300 px-1 rounded">| default: "val"</code> - Default value</li>
                <li><code class="bg-base-300 px-1 rounded">| upcase</code> - Uppercase</li>
              </ul>
            </div>
          </div>
        </div>
      </details>
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
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%!-- Field Header --%>
      <div class="px-4 py-3 bg-base-200/30 flex items-center justify-between">
        <div>
          <label class="font-medium text-sm text-base-content">{@field.label}</label>
          <p :if={@field.description} class="text-xs text-base-content/60 mt-0.5">
            {@field.description}
          </p>
        </div>
        <div class="flex items-center gap-2">
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
              <.icon name="hero-pencil" class="size-3" />
              Value
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
              <.icon name="hero-code-bracket" class="size-3" />
              Expression
            </button>
          </div>
        </div>
      </div>

      <%!-- Field Input --%>
      <div class="p-4 space-y-3">
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
    """
  end

  attr :field, :map, required: true
  attr :value, :any, required: true
  attr :myself, :any, required: true

  defp literal_input(assigns) do
    ~H"""
    <div>
      <%= case @field.type do %>
        <% :boolean -> %>
          <label class="flex items-center gap-3 cursor-pointer">
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@value == true or @value == "true"}
              phx-click="update_field"
              phx-value-field={@field.key}
              phx-value-value={if @value, do: "false", else: "true"}
              phx-target={@myself}
            />
            <span class="text-sm">{if @value, do: "Enabled", else: "Disabled"}</span>
          </label>
        <% :integer -> %>
          <input
            type="number"
            class="input input-bordered w-full"
            value={@value}
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          />
        <% :number -> %>
          <input
            type="number"
            step="any"
            class="input input-bordered w-full"
            value={@value}
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          />
        <% :textarea -> %>
          <textarea
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="4"
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          >{@value}</textarea>
        <% :json -> %>
          <textarea
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="6"
            spellcheck="false"
            phx-blur="update_field"
            phx-value-field={@field.key}
            phx-target={@myself}
          >{format_json(@value)}</textarea>
        <% _ -> %>
          <input
            type="text"
            class="input input-bordered w-full"
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
      <div class="relative">
        <div class="absolute top-2 left-3 text-secondary/60">
          <.icon name="hero-code-bracket" class="size-4" />
        </div>
        <textarea
          class={[
            "textarea w-full font-mono text-sm pl-10 bg-secondary/5 border-secondary/30",
            "focus:border-secondary focus:ring-secondary/20",
            @error && "border-error"
          ]}
          rows="3"
          spellcheck="false"
          placeholder='{{ nodes.PreviousNode.json.field }}'
          phx-blur="update_field"
          phx-value-field={@field.key}
          phx-target={@myself}
        >{@value}</textarea>
      </div>

      <%!-- Preview/Error Section --%>
      <%= cond do %>
        <% @error -> %>
          <div class="rounded-lg bg-error/10 border border-error/20 p-3">
            <div class="flex items-start gap-2">
              <.icon name="hero-exclamation-triangle" class="size-4 text-error mt-0.5" />
              <div>
                <p class="text-sm font-medium text-error">Expression Error</p>
                <p class="text-xs text-error/80 mt-1 font-mono">{@error}</p>
              </div>
            </div>
          </div>
        <% @has_context and @preview != nil -> %>
          <div class="rounded-lg bg-success/10 border border-success/20 p-3">
            <div class="flex items-start justify-between gap-2">
              <div class="flex items-start gap-2 min-w-0 flex-1">
                <.icon name="hero-check-circle" class="size-4 text-success mt-0.5 flex-shrink-0" />
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium text-success">Preview Result</p>
                  <pre class="text-xs text-base-content/80 mt-2 font-mono bg-base-200/50 p-2 rounded overflow-auto max-h-32">{format_preview(@preview)}</pre>
                </div>
              </div>
            </div>
          </div>
        <% @has_context -> %>
          <div class="rounded-lg bg-base-200/50 border border-base-300 p-3">
            <div class="flex items-center gap-2 text-base-content/60">
              <.icon name="hero-clock" class="size-4" />
              <p class="text-sm">Evaluating expression...</p>
            </div>
          </div>
        <% true -> %>
          <div class="rounded-lg bg-warning/10 border border-warning/20 p-3">
            <div class="flex items-start gap-2">
              <.icon name="hero-information-circle" class="size-4 text-warning mt-0.5" />
              <div>
                <p class="text-sm font-medium text-warning">Preview Unavailable</p>
                <p class="text-xs text-base-content/60 mt-1">
                  Run the workflow to see expression results
                </p>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  attr :node_output, :any, default: nil
  attr :show_pin_form, :boolean, default: false
  attr :pin_label, :string, default: ""
  attr :myself, :any, required: true

  defp output_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @node_output do %>
        <%!-- Output Data --%>
        <div>
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-medium text-base-content flex items-center gap-2">
              <.icon name="hero-arrow-up-on-square" class="size-4 text-success" />
              Last Execution Output
            </h3>
            <button
              type="button"
              class="btn btn-sm btn-outline btn-primary gap-2"
              phx-click="toggle_pin_form"
              phx-target={@myself}
            >
              <.icon name="hero-bookmark" class="size-4" />
              {if @show_pin_form, do: "Cancel", else: "Pin This Output"}
            </button>
          </div>

          <%!-- Pin Form --%>
          <%= if @show_pin_form do %>
            <div class="rounded-xl bg-primary/5 border border-primary/20 p-4 mb-4">
              <div class="flex items-end gap-3">
                <div class="flex-1">
                  <label class="label">
                    <span class="label-text text-sm font-medium">Pin Label (optional)</span>
                  </label>
                  <input
                    type="text"
                    class="input input-bordered w-full"
                    placeholder="e.g., Sample API response"
                    value={@pin_label}
                    phx-blur="update_pin_label"
                    phx-value-label={@pin_label}
                    phx-target={@myself}
                  />
                </div>
                <button
                  type="button"
                  class="btn btn-primary gap-2"
                  phx-click="pin_output"
                  phx-target={@myself}
                >
                  <.icon name="hero-bookmark-solid" class="size-4" />
                  Confirm Pin
                </button>
              </div>
              <p class="text-xs text-base-content/60 mt-2">
                Pinned data will be used instead of re-executing this node during testing.
              </p>
            </div>
          <% end %>

          <pre class="text-sm bg-base-200/50 p-4 rounded-xl overflow-auto max-h-96 border border-base-300 font-mono">{format_json(@node_output)}</pre>
        </div>
      <% else %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-arrow-up-on-square" class="size-12 mx-auto mb-3 opacity-30" />
          <p class="font-medium">No Output Available</p>
          <p class="text-sm mt-1">Run the workflow to capture this node's output</p>
        </div>
      <% end %>
    </div>
    """
  end

  attr :pinned_data, :map, default: nil
  attr :node_id, :string, required: true

  defp pinned_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @pinned_data do %>
        <%!-- Pin Info --%>
        <div class="rounded-xl bg-primary/5 border border-primary/20 p-4">
          <div class="flex items-start justify-between">
            <div class="flex items-start gap-3">
              <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/10 text-primary">
                <.icon name="hero-bookmark-solid" class="size-5" />
              </div>
              <div>
                <p class="font-medium text-base-content">
                  {@pinned_data["label"] || "Pinned Output"}
                </p>
                <p class="text-sm text-base-content/60 mt-0.5">
                  Pinned {format_relative_time(@pinned_data["pinned_at"])}
                </p>
              </div>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-sm text-error"
              phx-click="clear_pin"
              phx-value-node-id={@node_id}
            >
              <.icon name="hero-trash" class="size-4" />
              Remove
            </button>
          </div>

          <%= if @pinned_data["stale"] do %>
            <div class="mt-3 rounded-lg bg-warning/10 border border-warning/20 p-3 flex items-start gap-2">
              <.icon name="hero-exclamation-triangle" class="size-4 text-warning mt-0.5" />
              <div>
                <p class="text-sm font-medium text-warning">Pin is Stale</p>
                <p class="text-xs text-base-content/60">
                  Node configuration has changed since this data was pinned.
                </p>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Pinned Data Preview --%>
        <div>
          <h3 class="font-medium text-base-content mb-3 flex items-center gap-2">
            <.icon name="hero-document-text" class="size-4 opacity-70" />
            Pinned Data
          </h3>
          <pre class="text-sm bg-base-200/50 p-4 rounded-xl overflow-auto max-h-96 border border-base-300 font-mono">{format_json(@pinned_data["data"])}</pre>
        </div>
      <% else %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-bookmark" class="size-12 mx-auto mb-3 opacity-30" />
          <p class="font-medium">No Pinned Data</p>
          <p class="text-sm mt-1">Pin node output to reuse it during testing</p>
          <p class="text-xs mt-4 max-w-sm mx-auto">
            Pinned data lets you skip re-executing upstream nodes and test with consistent data.
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
