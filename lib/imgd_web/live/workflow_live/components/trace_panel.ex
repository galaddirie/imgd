defmodule ImgdWeb.WorkflowLive.Components.TracePanel do
  @moduledoc """
  A component that displays execution trace as a timeline.

  Shows:
  - Step execution order
  - Timing information
  - Status indicators
  - Expandable error details
  """
  use Phoenix.Component

  import ImgdWeb.CoreComponents
  import ImgdWeb.Formatters


  attr :execution, :map, default: nil
  attr :steps, :list, default: []
  attr :running, :boolean, default: false

  def trace_panel(assigns) do
    ~H"""
    <div class="trace-panel rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden">
      <div class="px-4 py-3 border-b border-base-200 bg-base-50 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-queue-list" class="size-5 text-base-content/70" />
          <h3 class="font-semibold text-sm text-base-content">Execution Trace</h3>
        </div>
        <%= if @running do %>
          <span class="inline-flex items-center gap-1.5 text-xs text-primary">
            <span class="size-2 rounded-full bg-primary animate-pulse"></span>
            Running
          </span>
        <% end %>
      </div>

      <div class="max-h-80 overflow-y-auto">
        <%= if @execution do %>
          <div class="divide-y divide-base-200">
            <%!-- Execution header --%>
            <.trace_item
              icon="hero-play-circle"
              icon_class="text-primary"
              title="Execution Started"
              subtitle={format_time(@execution.started_at)}
              meta={@execution.id}
            />

            <%!-- Step entries --%>
            <%= for step <- @steps do %>
              <.step_trace_item step={step} />
            <% end %>

            <%!-- Completion entry --%>
            <%= if @execution.status in [:completed, :failed, :cancelled, :timeout] do %>
              <.trace_item
                icon={completion_icon(@execution.status)}
                icon_class={completion_icon_class(@execution.status)}
                title={completion_title(@execution.status)}
                subtitle={format_time(@execution.completed_at)}
                meta={format_duration_from_execution(@execution)}
              />
            <% end %>
          </div>
        <% else %>
          <div class="p-8 text-center text-base-content/50">
            <.icon name="hero-clock" class="size-8 mx-auto mb-2" />
            <p class="text-sm">No execution in progress</p>
            <p class="text-xs mt-1">Run the workflow to see trace here</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp trace_item(assigns) do
    assigns =
      assigns
      |> assign_new(:meta, fn -> nil end)
      |> assign_new(:error, fn -> nil end)

    ~H"""
    <div class="px-4 py-3 flex items-start gap-3 hover:bg-base-50 transition-colors">
      <div class="flex-shrink-0 mt-0.5">
        <.icon name={@icon} class={["size-5", @icon_class]} />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm text-base-content truncate">{@title}</span>
          <%= if @meta do %>
            <span class="text-xs text-base-content/50 font-mono">{@meta}</span>
          <% end %>
        </div>
        <p class="text-xs text-base-content/60 mt-0.5">{@subtitle}</p>
        <%= if @error do %>
          <div class="mt-2 p-2 rounded bg-error/10 border border-error/20">
            <p class="text-xs text-error font-mono">{@error}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp step_trace_item(assigns) do
    step = assigns.step

    {icon, icon_class} = step_icon_and_class(step.status)
    subtitle = step_subtitle(step)

    assigns =
      assigns
      |> assign(:icon, icon)
      |> assign(:icon_class, icon_class)
      |> assign(:subtitle, subtitle)

    ~H"""
    <div class="px-4 py-3 flex items-start gap-3 hover:bg-base-50 transition-colors">
      <div class="flex-shrink-0 mt-0.5 relative">
        <%!-- Connecting line --%>
        <div class="absolute left-1/2 -top-3 w-px h-3 bg-base-300"></div>
        <.icon name={@icon} class={["size-5", @icon_class]} />
        <%= if @step.status == :running do %>
          <span class="absolute -right-1 -top-1 size-2 rounded-full bg-primary animate-ping"></span>
        <% end %>
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm text-base-content truncate">
            {@step.step_name}
          </span>
          <%= if @step.duration_ms do %>
            <span class="text-xs text-base-content/50 font-mono">{@step.duration_ms}ms</span>
          <% end %>
        </div>
        <div class="flex items-center gap-2 mt-0.5">
          <span class={["text-xs", status_text_class(@step.status)]}>
            {format_status(@step.status)}
          </span>
          <span class="text-xs text-base-content/40">•</span>
          <span class="text-xs text-base-content/60">{@subtitle}</span>
        </div>
        <%= if @step.status == :failed && @step[:error] do %>
          <div class="mt-2 p-2 rounded bg-error/10 border border-error/20">
            <p class="text-xs text-error font-mono truncate">{format_error(@step.error)}</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions

  defp step_icon_and_class(status) do
    case status do
      :completed -> {"hero-check-circle-solid", "text-success"}
      :failed -> {"hero-x-circle-solid", "text-error"}
      :running -> {"hero-arrow-path", "text-primary animate-spin"}
      :retrying -> {"hero-arrow-path", "text-warning"}
      :skipped -> {"hero-minus-circle", "text-base-content/40"}
      :pending -> {"hero-clock", "text-base-content/40"}
      _ -> {"hero-question-mark-circle", "text-base-content/40"}
    end
  end

  defp status_text_class(status) do
    case status do
      :completed -> "text-success"
      :failed -> "text-error"
      :running -> "text-primary"
      :retrying -> "text-warning"
      _ -> "text-base-content/50"
    end
  end

  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(:running), do: "Running"
  defp format_status(:retrying), do: "Retrying"
  defp format_status(:skipped), do: "Skipped"
  defp format_status(:pending), do: "Pending"
  defp format_status(status), do: to_string(status)

  defp step_subtitle(step) do
    parts = []

    parts =
      if step[:step_type] do
        [step.step_type | parts]
      else
        parts
      end

    parts =
      if step[:generation] do
        ["Gen #{step.generation}" | parts]
      else
        parts
      end

    parts =
      if step[:attempt] && step.attempt > 1 do
        ["Attempt #{step.attempt}" | parts]
      else
        parts
      end

    Enum.join(Enum.reverse(parts), " • ")
  end

  defp completion_icon(:completed), do: "hero-check-circle-solid"
  defp completion_icon(:failed), do: "hero-x-circle-solid"
  defp completion_icon(:cancelled), do: "hero-stop-circle-solid"
  defp completion_icon(:timeout), do: "hero-clock"
  defp completion_icon(_), do: "hero-question-mark-circle"

  defp completion_icon_class(:completed), do: "text-success"
  defp completion_icon_class(:failed), do: "text-error"
  defp completion_icon_class(:cancelled), do: "text-warning"
  defp completion_icon_class(:timeout), do: "text-error"
  defp completion_icon_class(_), do: "text-base-content/50"

  defp completion_title(:completed), do: "Execution Completed"
  defp completion_title(:failed), do: "Execution Failed"
  defp completion_title(:cancelled), do: "Execution Cancelled"
  defp completion_title(:timeout), do: "Execution Timed Out"
  defp completion_title(_), do: "Execution Ended"

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S.%f")
    |> String.slice(0, 12)
  end

  defp format_duration_from_execution(%{started_at: started, completed_at: completed})
       when not is_nil(started) and not is_nil(completed) do
    ms = DateTime.diff(completed, started, :millisecond)
    format_duration(ms)
  end

  defp format_duration_from_execution(_), do: nil

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 2)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_error(%{message: msg}), do: msg
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
