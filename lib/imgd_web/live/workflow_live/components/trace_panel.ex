defmodule ImgdWeb.WorkflowLive.Components.TracePanel do
  @moduledoc """
  Component for displaying execution trace steps.
  """
  use ImgdWeb, :html

  import ImgdWeb.Formatters

  attr :execution, :map, required: true
  attr :steps, :list, required: true
  attr :running, :boolean, default: false

  def trace_panel(assigns) do
    ~H"""
    <div>
      <div class="border-b border-base-200 px-4 py-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold text-base-content flex items-center gap-2">
          <.icon name="hero-document-text" class="size-4 opacity-70" /> Execution Trace
        </h2>
        <%= if @running do %>
          <span class="badge badge-info badge-sm animate-pulse">Running</span>
        <% end %>
      </div>

      <div class="p-4">
        <%= if Enum.empty?(@steps) do %>
          <div class="text-center py-8 text-base-content/60">
            <p class="text-sm">No trace steps available</p>
          </div>
        <% else %>
          <div class="space-y-2">
            <%= for step <- @steps do %>
              <div class="flex items-start gap-3 p-2 rounded-lg bg-base-200/30">
                <div class={[
                  "flex-shrink-0 w-6 h-6 rounded-full flex items-center justify-center text-xs font-medium",
                  step_status_class(step.status)
                ]}>
                  {step_status_icon(step.status)}
                </div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-medium text-base-content">{step.node_name}</span>
                    <span class="text-xs text-base-content/60 font-mono">{step.node_id}</span>
                  </div>
                  <div class="text-xs text-base-content/60 mt-1">
                    {step.type_id} • {format_duration(step.duration_us)}
                  </div>
                  <%= if step.error do %>
                    <div class="mt-2 p-2 bg-error/10 text-error text-xs rounded-lg">
                      {inspect(step.error)}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp step_status_class(:completed), do: "bg-success text-success-content"
  defp step_status_class(:failed), do: "bg-error text-error-content"
  defp step_status_class(:running), do: "bg-info text-info-content"
  defp step_status_class(:pending), do: "bg-warning text-warning-content"
  defp step_status_class(_), do: "bg-base-300 text-base-content"

  defp step_status_icon(:completed), do: "✓"
  defp step_status_icon(:failed), do: "✗"
  defp step_status_icon(:running), do: "⟳"
  defp step_status_icon(:pending), do: "○"
  defp step_status_icon(_), do: "?"

end
