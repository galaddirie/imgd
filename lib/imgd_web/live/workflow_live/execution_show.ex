defmodule ImgdWeb.WorkflowLive.ExecutionShow do
  @moduledoc """
  LiveView for inspecting a specific workflow execution.

  Surfaces execution metadata, inputs/outputs, checkpoints, and individual step
  records to help debug and replay executions.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias ImgdWeb.WorkflowLive.Components.TracePanel
  import ImgdWeb.Formatters

  @impl true
  def mount(%{"workflow_id" => workflow_id, "id" => execution_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, execution} <- fetch_execution(scope, workflow_id, execution_id) do
      steps = Workflows.list_execution_steps(scope, execution)
      checkpoints = Workflows.list_checkpoints(scope, execution)

      socket =
        socket
        |> assign(:workflow, execution.workflow)
        |> assign(:execution, execution)
        |> assign(:checkpoints, checkpoints)
        |> assign(:steps, steps)
        |> assign(:page_title, "Execution #{short_id(execution.id)}")
        |> assign(:duration_ms, execution_duration_ms(execution))
        |> assign(:steps_empty?, steps == [])
        |> assign(:checkpoints_empty?, checkpoints == [])
        |> assign(:trace_steps, steps)
        |> stream(:steps, steps, reset: true)
        |> stream(:checkpoints, checkpoints, reset: true)

      {:ok, socket}
    else
      _ ->
        socket =
          socket
          |> put_flash(:error, "Execution not found")
          |> redirect(to: ~p"/workflows/#{workflow_id}")

        {:ok, socket}
    end
  end

  defp fetch_execution(scope, workflow_id, execution_id) do
    execution = Workflows.get_execution!(scope, execution_id)

    if execution.workflow_id == workflow_id do
      {:ok, execution}
    else
      {:error, :workflow_mismatch}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <div class="flex items-center gap-3">
                <.link navigate={~p"/workflows/#{@workflow.id}"} class="btn btn-ghost btn-sm">
                  <.icon name="hero-arrow-left" class="size-4" />
                  <span>Back to Workflow</span>
                </.link>
                <span class="text-[11px] font-mono uppercase tracking-wide text-base-content/60">
                  {short_id(@workflow.id)}
                </span>
              </div>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                  Execution {short_id(@execution.id)}
                </h1>
                <span class={["badge badge-sm", execution_status_badge(@execution.status)]}>
                  {@execution.status}
                </span>
                <span class="badge badge-ghost badge-xs">v{@execution.workflow_version}</span>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                Detailed run history for {@workflow.name}. Use checkpoints and step logs to debug.
              </p>
              <div class="flex flex-wrap items-center gap-4 text-xs text-base-content/60">
                <div class="flex items-center gap-1">
                  <.icon name="hero-clock" class="size-4" />
                  <span>Started {formatted_timestamp(@execution.started_at)}</span>
                </div>
                <%= if @execution.completed_at do %>
                  <div class="flex items-center gap-1">
                    <.icon name="hero-flag" class="size-4" />
                    <span>Completed {formatted_timestamp(@execution.completed_at)}</span>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="flex gap-3">
              <.link
                navigate={~p"/workflows/#{@workflow.id}/executions/#{@execution.id}"}
                class="btn btn-primary btn-sm gap-2"
                id="execution-detail-refresh"
              >
                <.icon name="hero-arrow-path" class="size-4" />
                <span>Refresh</span>
              </.link>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <div class="grid grid-cols-1 xl:grid-cols-3 gap-6">
            <div class="xl:col-span-2 space-y-4">
              <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
                <div class="flex items-center justify-between mb-4">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-rectangle-stack" class="size-5" />
                    <h2 class="text-lg font-semibold text-base-content">Execution Overview</h2>
                  </div>
                  <span class="badge badge-outline badge-sm">
                    {String.capitalize(to_string(@execution.trigger_type))}
                  </span>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <.metric
                    title="Status"
                    icon="hero-circle-stack"
                    value={String.capitalize(to_string(@execution.status))}
                  />
                  <.metric
                    title="Duration"
                    icon="hero-stopwatch"
                    value={format_duration(@duration_ms)}
                    hint="Total runtime from start to completion"
                  />
                  <.metric
                    title="Generation"
                    icon="hero-bolt"
                    value={"Gen #{@execution.current_generation}"}
                    hint="Current workflow generation"
                  />
                  <.metric
                    title="Started At"
                    icon="hero-clock"
                    value={formatted_timestamp(@execution.started_at)}
                  />
                  <.metric
                    title="Completed At"
                    icon="hero-flag"
                    value={formatted_timestamp(@execution.completed_at)}
                  />
                  <.metric
                    title="Workflow Version"
                    icon="hero-arrow-up-on-square-stack"
                    value={"v#{@execution.workflow_version}"}
                  />
                </div>
              </div>

              <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
                <div class="flex items-center justify-between mb-4">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-document-text" class="size-5" />
                    <h3 class="text-lg font-semibold text-base-content">Inputs &amp; Output</h3>
                  </div>
                  <span class="text-xs text-base-content/60">Debug snapshots</span>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="space-y-2">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Input
                    </p>
                    <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap">
                      <code><%= pretty_data(@execution.input) %></code>
                    </pre>
                  </div>

                  <div class="space-y-2">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Output
                    </p>
                    <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap">
                      <code><%= pretty_data(@execution.output) %></code>
                    </pre>
                  </div>
                </div>

                <div class="mt-4 grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div class="space-y-2">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Triggered By
                    </p>
                    <p class="text-sm text-base-content/80">
                      {@execution.metadata["triggered_by"] || "User"}
                    </p>
                  </div>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Error
                    </p>
                    <%= if @execution.error do %>
                      <pre class="rounded-xl bg-error/10 border border-error/20 p-3 text-xs font-mono text-error whitespace-pre-wrap">
                        <code><%= pretty_data(@execution.error) %></code>
                      </pre>
                    <% else %>
                      <p class="text-sm text-base-content/70">None recorded</p>
                    <% end %>
                  </div>
                  <div class="space-y-2">
                    <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Metadata
                    </p>
                    <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap">
                      <code><%= pretty_data(@execution.metadata) %></code>
                    </pre>
                  </div>
                </div>
              </div>
            </div>

            <div class="space-y-4">
              <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
                <div class="flex items-center gap-2 mb-4">
                  <.icon name="hero-chart-bar" class="size-5" />
                  <h3 class="text-lg font-semibold text-base-content">Execution Stats</h3>
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <.stat
                    title="Steps Completed"
                    value={stat_value(@execution.stats, :steps_completed)}
                  />
                  <.stat title="Steps Failed" value={stat_value(@execution.stats, :steps_failed)} />
                  <.stat title="Steps Skipped" value={stat_value(@execution.stats, :steps_skipped)} />
                  <.stat title="Retries" value={stat_value(@execution.stats, :retries)} />
                  <.stat
                    title="Total Duration"
                    value={format_duration(stat_value(@execution.stats, :total_duration_ms))}
                  />
                  <.stat title="Current Generation" value={@execution.current_generation} />
                </div>
              </div>

              <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
                <TracePanel.trace_panel
                  execution={@execution}
                  steps={@trace_steps}
                  running={@execution.status == :running}
                />
              </div>
            </div>
          </div>
        </section>

        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-2">
                <.icon name="hero-command-line" class="size-5" />
                <h3 class="text-lg font-semibold text-base-content">Step Details</h3>
              </div>
              <span class="text-xs text-base-content/60">Inspect IO, errors, and timing</span>
            </div>

            <div id="execution-steps" phx-update="stream" class="space-y-3">
              <div class="hidden only:block text-center text-sm text-base-content/60 py-4">
                No steps recorded yet.
              </div>
              <div
                :for={{id, step} <- @streams.steps}
                id={id}
                class="rounded-xl border border-base-200 p-4 hover:border-primary/30 transition-colors"
              >
                <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                  <div class="space-y-1">
                    <div class="flex items-center gap-2">
                      <p class="text-base font-semibold text-base-content">{step.step_name}</p>
                      <span class={["badge badge-xs", execution_status_badge(step.status)]}>
                        {step.status}
                      </span>
                    </div>
                    <div class="flex flex-wrap items-center gap-3 text-xs text-base-content/60">
                      <span class="inline-flex items-center gap-1">
                        <.icon name="hero-hashtag" class="size-4" /> {step.step_hash}
                      </span>
                      <span class="inline-flex items-center gap-1">
                        <.icon name="hero-bolt" class="size-4" /> Gen {step.generation}
                      </span>
                      <span class="inline-flex items-center gap-1">
                        <.icon name="hero-arrow-path" class="size-4" /> Attempt {step.attempt}
                      </span>
                      <%= if step.duration_ms do %>
                        <span class="inline-flex items-center gap-1">
                          <.icon name="hero-stopwatch" class="size-4" /> {format_duration(
                            step.duration_ms
                          )}
                        </span>
                      <% end %>
                    </div>
                  </div>
                  <div class="text-xs text-base-content/60 space-y-1 text-right">
                    <p>Started {formatted_timestamp(step.started_at)}</p>
                    <p>Completed {formatted_timestamp(step.completed_at)}</p>
                  </div>
                </div>

                <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
                  <div class="space-y-2">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
                      Input Snapshot
                    </p>
                    <pre class="rounded-lg bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap">
                      <code><%= pretty_data(step.input_snapshot) %></code>
                    </pre>
                  </div>
                  <div class="space-y-2">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
                      Output Snapshot
                    </p>
                    <pre class="rounded-lg bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap">
                      <code><%= pretty_data(step.output_snapshot) %></code>
                    </pre>
                  </div>
                </div>

                <%= if step.error do %>
                  <div class="mt-3 rounded-lg border border-error/20 bg-error/10 p-3">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-error mb-2">
                      Error
                    </p>
                    <pre class="text-xs font-mono text-error whitespace-pre-wrap">
                      <code><%= pretty_data(step.error) %></code>
                    </pre>
                  </div>
                <% end %>

                <%= if step.logs do %>
                  <div class="mt-3 rounded-lg border border-base-200 bg-base-200/40 p-3">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60 mb-2">
                      Logs
                    </p>
                    <pre class="text-xs font-mono text-base-content/80 whitespace-pre-wrap">{step.logs}</pre>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </section>

        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5" />
                <h3 class="text-lg font-semibold text-base-content">Checkpoints</h3>
              </div>
              <span class="text-xs text-base-content/60">Latest first</span>
            </div>

            <div id="execution-checkpoints" phx-update="stream" class="space-y-3">
              <div class="hidden only:block text-center text-sm text-base-content/60 py-4">
                No checkpoints have been captured for this execution yet.
              </div>

              <div
                :for={{id, checkpoint} <- @streams.checkpoints}
                id={id}
                class={[
                  "rounded-xl border p-4 transition-colors",
                  checkpoint.is_current && "border-primary/40 bg-primary/5",
                  !checkpoint.is_current && "border-base-200 hover:border-primary/30"
                ]}
              >
                <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                  <div class="space-y-1">
                    <div class="flex items-center gap-2">
                      <p class="text-base font-semibold text-base-content">
                        Generation {checkpoint.generation}
                      </p>
                      <span class="badge badge-ghost badge-xs">
                        {String.capitalize(to_string(checkpoint.reason))}
                      </span>
                      <%= if checkpoint.is_current do %>
                        <span class="badge badge-primary badge-xs">Current</span>
                      <% end %>
                    </div>
                    <p class="text-xs text-base-content/60">
                      Saved {formatted_timestamp(checkpoint.inserted_at)}
                    </p>
                  </div>
                  <div class="flex flex-wrap gap-3 text-xs text-base-content/60">
                    <span class="inline-flex items-center gap-1">
                      <.icon name="hero-rectangle-group" class="size-4" /> {byte_size_label(
                        checkpoint.size_bytes
                      )}
                    </span>
                    <span class="inline-flex items-center gap-1">
                      <.icon name="hero-queue-list" class="size-4" />
                      Pending {length(checkpoint.pending_runnables || [])}
                    </span>
                    <span class="inline-flex items-center gap-1">
                      <.icon name="hero-check" class="size-4" />
                      Completed {length(checkpoint.completed_step_hashes || [])}
                    </span>
                  </div>
                </div>

                <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3">
                  <div class="space-y-2">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
                      Pending Runnables
                    </p>
                    <%= if Enum.empty?(checkpoint.pending_runnables || []) do %>
                      <p class="text-sm text-base-content/60">None queued</p>
                    <% else %>
                      <div class="rounded-lg bg-base-200/60 p-3 text-xs font-mono text-base-content/80 space-y-1">
                        <%= for runnable <- checkpoint.pending_runnables do %>
                          <p>
                            node: {runnable["node_hash"] || runnable[:node_hash]},
                            fact: {runnable["fact_hash"] || runnable[:fact_hash]}
                          </p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="space-y-2">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
                      Accumulator States
                    </p>
                    <%= if map_size(checkpoint.accumulator_states || %{}) == 0 do %>
                      <p class="text-sm text-base-content/60">No accumulators recorded</p>
                    <% else %>
                      <pre class="rounded-lg bg-base-200/60 p-3 text-xs font-mono text-base-content/80 whitespace-pre-wrap">
                        <code><%= pretty_data(checkpoint.accumulator_states) %></code>
                      </pre>
                    <% end %>
                  </div>

                  <div class="space-y-2">
                    <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
                      Completed Step Hashes
                    </p>
                    <%= if Enum.empty?(checkpoint.completed_step_hashes || []) do %>
                      <p class="text-sm text-base-content/60">
                        No steps completed at this checkpoint
                      </p>
                    <% else %>
                      <div class="rounded-lg bg-base-200/60 p-3 text-xs font-mono text-base-content/80 space-y-1">
                        <%= for hash <- checkpoint.completed_step_hashes do %>
                          <p>{hash}</p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-2">
                <.icon name="hero-code-bracket" class="size-5" />
                <h3 class="text-lg font-semibold text-base-content">Full Execution Data (JSON)</h3>
              </div>
              <span class="text-xs text-base-content/60">Copy for debugging</span>
            </div>

            <div class="relative">
              <pre class="rounded-xl bg-base-200/60 p-4 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap max-h-96 overflow-y-auto">
                <code><%= Jason.encode!(%{workflow: @workflow, execution: @execution, checkpoints: @checkpoints, steps: @steps}, pretty: true) %></code>
              </pre>
              <button
                class="absolute top-3 right-3 btn btn-ghost btn-xs gap-1"
                onclick="navigator.clipboard.writeText(this.previousElementSibling.textContent)"
                title="Copy to clipboard"
              >
                <.icon name="hero-clipboard-document" class="size-4" />
                <span class="hidden sm:inline">Copy</span>
              </button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Components

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :hint, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-200/50 p-3 shadow-inner">
      <div class="flex items-center gap-2 text-xs text-base-content/60 mb-1">
        <.icon name={@icon} class="size-4" />
        <span class="font-semibold uppercase tracking-wide">{@title}</span>
      </div>
      <p class="text-base font-semibold text-base-content">{@value}</p>
      <%= if @hint do %>
        <p class="text-[11px] text-base-content/60 mt-1">{@hint}</p>
      <% end %>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-50 p-3">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">{@title}</p>
      <p class="text-lg font-semibold text-base-content mt-1">{@value}</p>
    </div>
    """
  end

  # Helpers

  defp execution_status_badge(:completed), do: "badge-success"
  defp execution_status_badge(:failed), do: "badge-error"
  defp execution_status_badge(:running), do: "badge-info"
  defp execution_status_badge(:pending), do: "badge-warning"
  defp execution_status_badge(:paused), do: "badge-warning"
  defp execution_status_badge(:cancelled), do: "badge-neutral"
  defp execution_status_badge(:timeout), do: "badge-error"
  defp execution_status_badge(_), do: "badge-ghost"

  defp execution_duration_ms(%{stats: %{"total_duration_ms" => ms}}) when is_number(ms), do: ms
  defp execution_duration_ms(%{stats: %{total_duration_ms: ms}}) when is_number(ms), do: ms

  defp execution_duration_ms(%{started_at: started, completed_at: completed})
       when not is_nil(started) and not is_nil(completed) do
    DateTime.diff(completed, started, :millisecond)
  end

  defp execution_duration_ms(_), do: nil

  defp stat_value(stats, key) do
    cond do
      is_map(stats) && Map.has_key?(stats, to_string(key)) -> stats[to_string(key)]
      is_map(stats) && Map.has_key?(stats, key) -> stats[key]
      true -> 0
    end
  end

  defp pretty_data(nil), do: "-"

  defp pretty_data(data) do
    try do
      inspect(data, pretty: true, limit: 200)
    rescue
      _ -> inspect(data)
    end
  end

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: "#{Float.round(ms / 1000, 2)}s"

  defp format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 60_000, 1)}m"
  defp format_duration(value), do: inspect(value)

  defp byte_size_label(nil), do: "-"
  defp byte_size_label(size) when size < 1024, do: "#{size} B"
  defp byte_size_label(size) when size < 1_048_576, do: "#{Float.round(size / 1024, 1)} KB"
  defp byte_size_label(size), do: "#{Float.round(size / 1_048_576, 2)} MB"
end
