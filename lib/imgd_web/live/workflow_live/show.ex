defmodule ImgdWeb.WorkflowLive.Show do
  @moduledoc """
  LiveView for showing a workflow with graph visualization and execution.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias ImgdWeb.WorkflowLive.Components.WorkflowGraph
  import ImgdWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    try do
      workflow = Workflows.get_workflow!(scope, id)
      executions = Workflows.list_executions(scope, workflow, limit: 10)

      socket =
        socket
        |> assign(:page_title, workflow.name)
        |> assign(:workflow, workflow)
        |> assign(:executions, executions)
        |> assign(:execution_result, nil)
        |> assign(:running, false)
        |> assign_run_form("5")

      {:ok, socket}
    rescue
      _ ->
        socket =
          socket
          |> put_flash(:error, "Workflow not found")
          |> redirect(to: ~p"/workflows")

        {:ok, socket}
    end
  end


  @impl true
  def handle_event("update_input", %{"run" => %{"input" => input}}, socket) do
    {:noreply, assign_run_form(socket, input)}
  end

  def handle_event("update_input", %{"input" => input}, socket) do
    {:noreply, assign_run_form(socket, input)}
  end

  @impl true
  def handle_event("run_workflow", %{"run" => %{"input" => input}}, socket) do
    socket =
      socket
      |> assign(running: true, execution_result: nil)
      |> assign_run_form(input)

    # Parse the input (try as integer, then float, then keep as string)
    input = parse_input(input)

    # TODO: Implement workflow execution
    result = %{status: :failed, error: "Workflow execution not yet implemented"}

    # Refresh executions list
    executions =
      Workflows.list_executions(
        socket.assigns.current_scope,
        socket.assigns.workflow,
        limit: 10
      )

    {:noreply,
     assign(socket,
       running: false,
       execution_result: result,
       executions: executions
     )}
  end

  def handle_event("run_workflow", _params, socket) do
    handle_event("run_workflow", %{"run" => %{"input" => socket.assigns.run_input}}, socket)
  end

  defp assign_run_form(socket, input) do
    assign(socket,
      run_input: input,
      run_form: to_form(%{"input" => input}, as: :run)
    )
  end

  defp parse_input(input) do
    cond do
      match?({_int, ""}, Integer.parse(input)) ->
        {int, ""} = Integer.parse(input)
        int

      match?({_float, ""}, Float.parse(input)) ->
        {float, ""} = Float.parse(input)
        float

      true ->
        input
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <div class="flex items-center gap-3">
                <.link navigate={~p"/workflows"} class="btn btn-ghost btn-sm">
                  <.icon name="hero-arrow-left" class="size-4" />
                  <span>Back to Workflows</span>
                </.link>
              </div>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                  {@workflow.name}
                </h1>
                <span class="badge badge-ghost badge-xs">v{@workflow.version}</span>
                <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                  {status_label(@workflow.status)}
                </span>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                {@workflow.description || "No description provided."}
              </p>
              <div class="flex items-center gap-4 text-xs text-base-content/60">
                <div class="flex items-center gap-1">
                  <.icon name="hero-clock" class="size-4" />
                  <span>Updated {formatted_timestamp(@workflow.updated_at)}</span>
                </div>
                <div class="text-[11px] font-mono uppercase tracking-wide">
                  {short_id(@workflow.id)}
                </div>
              </div>
            </div>

          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <%!-- Workflow Graph Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-share" class="size-5" /> Workflow Graph
            </h2>
            <.live_component
              module={WorkflowGraph}
              id={"workflow-graph-#{@workflow.id}"}
              workflow={@workflow}
            />
          </div>
        </section>

        <%!-- Run Workflow Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-play" class="size-5" /> Run Workflow
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              Enter an input value to execute the workflow
            </p>

            <.form
              for={@run_form}
              id="run-workflow-form"
              phx-change="update_input"
              phx-submit="run_workflow"
              phx-debounce="300"
              class="space-y-4"
            >
              <div class="space-y-4">
                <div class="flex gap-4 items-end">
                  <div class="flex-1 space-y-2">
                    <label class="text-sm font-medium text-base-content/80">Input Value</label>
                    <input
                      type="text"
                      name="run[input]"
                      value={Phoenix.HTML.Form.normalize_value("text", @run_form[:input].value)}
                      placeholder="Enter a number or value..."
                      inputmode="decimal"
                      class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base shadow-inner transition focus:border-primary focus:ring-2 focus:ring-primary/25"
                    />
                  </div>
                  <button
                    type="submit"
                    id="run-workflow-submit"
                    class="inline-flex items-center gap-2 rounded-xl bg-primary px-6 py-3 text-sm font-semibold text-primary-content shadow-lg shadow-primary/20 transition hover:-translate-y-0.5 hover:shadow-xl focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary disabled:translate-y-0 disabled:opacity-60 disabled:shadow-none whitespace-nowrap"
                    disabled={@running || @workflow.status != :published}
                  >
                    <%= if @running do %>
                      <span class="flex h-4 w-4 items-center justify-center">
                        <span class="h-4 w-4 animate-spin rounded-full border-2 border-primary-content/30 border-t-primary-content">
                        </span>
                      </span>
                      <span>Running...</span>
                    <% else %>
                      <.icon name="hero-play" class="size-4" />
                      <span>Run Workflow</span>
                    <% end %>
                  </button>
                </div>
                <p class="text-xs text-base-content/70 leading-relaxed">
                  Numbers will be parsed automatically. Try: 5, 10, 15
                </p>
              </div>

              <%!-- Execution Result --%>
              <%= if @execution_result do %>
                <div class={[
                  "rounded-xl border p-4 shadow-sm mt-4",
                  if(@execution_result.status == :completed,
                    do: "border-success/30 bg-success/10",
                    else: "border-error/30 bg-error/10"
                  )
                ]}>
                  <div class="flex items-start gap-3">
                    <%= if @execution_result.status == :completed do %>
                      <.icon name="hero-check-circle" class="size-5 text-success flex-shrink-0 mt-0.5" />
                    <% else %>
                      <.icon name="hero-x-circle" class="size-5 text-error flex-shrink-0 mt-0.5" />
                    <% end %>
                    <div class="flex-1 min-w-0 space-y-2">
                      <p class={[
                        "font-medium text-sm",
                        if(@execution_result.status == :completed,
                          do: "text-success",
                          else: "text-error"
                        )
                      ]}>
                        {if @execution_result.status == :completed,
                          do: "Execution Completed",
                          else: "Execution Failed"}
                      </p>

                      <%= if @execution_result[:execution] do %>
                        <div class="space-y-2">
                          <div>
                            <span class="text-xs font-medium text-base-content/70">Output</span>
                            <pre class="mt-1 text-xs bg-base-200/70 p-3 rounded-lg overflow-x-auto"><code>{format_output(@execution_result.execution.output)}</code></pre>
                          </div>
                          <div class="flex flex-wrap gap-4 text-xs text-base-content/70">
                            <span class="inline-flex items-center gap-1 rounded-full bg-base-200/70 px-2 py-1">
                              <.icon name="hero-clock" class="size-4" />
                              {format_duration(
                                get_duration_from_stats(@execution_result.execution.stats)
                              )}
                            </span>
                            <span class="inline-flex items-center gap-1 rounded-full bg-base-200/70 px-2 py-1">
                              <.icon name="hero-bolt" class="size-4" />
                              {get_generation(@execution_result.execution.output)} generations
                            </span>
                          </div>
                        </div>
                      <% end %>

                      <%= if @execution_result[:error] do %>
                        <div>
                          <pre class="text-xs bg-base-200/70 p-3 rounded-lg overflow-x-auto text-error"><code>{inspect(@execution_result.error, pretty: true)}</code></pre>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </.form>
          </div>
        </section>

        <%!-- Recent Executions Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-clock" class="size-5" /> Recent Executions
            </h2>

            <%= if Enum.empty?(@executions) do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
                <p class="text-sm">No executions yet</p>
                <p class="text-xs mt-1">Run the workflow to see results here</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th>Status</th>
                      <th>Input</th>
                      <th>Output</th>
                      <th>Duration</th>
                      <th>Started</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for execution <- @executions do %>
                      <tr class="hover">
                        <td class="font-mono text-xs">{short_id(execution.id)}</td>
                        <td>
                          <span class={["badge badge-xs", execution_status_class(execution.status)]}>
                            {execution.status}
                          </span>
                        </td>
                        <td class="max-w-32 truncate text-xs">
                          {format_execution_value(execution.input)}
                        </td>
                        <td class="max-w-48 truncate text-xs">
                          {format_execution_value(execution.output)}
                        </td>
                        <td class="text-xs">
                          {format_duration(get_duration_from_stats(execution.stats))}
                        </td>
                        <td class="text-xs text-base-content/60">
                          {format_relative_time(execution.started_at)}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </section>

        <%!-- Workflow Details Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="hero-information-circle" class="size-5" /> Workflow Details
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Trigger</label>
                  <div class="flex items-center gap-2 mt-1">
                    <.icon name="hero-bolt" class="size-4 opacity-70" />
                    <span class="text-sm">{trigger_label(@workflow)}</span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Status</label>
                  <div class="mt-1">
                    <span class={["badge badge-sm", status_badge_class(@workflow.status)]}>
                      {status_label(@workflow.status)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Version</label>
                  <div class="mt-1">
                    <span class="text-sm">v{@workflow.version}</span>
                  </div>
                </div>
              </div>

              <div class="space-y-4">
                <div>
                  <label class="text-sm font-medium text-base-content/70">Created</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.inserted_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Last Updated</label>
                  <div class="mt-1">
                    <span class="text-sm text-base-content/60">
                      {formatted_timestamp(@workflow.updated_at)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="text-sm font-medium text-base-content/70">Workflow ID</label>
                  <div class="mt-1">
                    <code class="text-xs bg-base-200 px-2 py-1 rounded">{@workflow.id}</code>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>

    </Layouts.app>
    """
  end

  # Helper functions

  defp execution_status_class(:completed), do: "badge-success"
  defp execution_status_class(:failed), do: "badge-error"
  defp execution_status_class(:running), do: "badge-info"
  defp execution_status_class(:pending), do: "badge-warning"
  defp execution_status_class(:paused), do: "badge-warning"
  defp execution_status_class(:cancelled), do: "badge-neutral"
  defp execution_status_class(:timeout), do: "badge-error"
  defp execution_status_class(_), do: "badge-ghost"

  defp format_execution_value(nil), do: "-"
  defp format_execution_value(%{"value" => value}), do: inspect(value)
  defp format_execution_value(%{"productions" => prods}) when is_list(prods), do: inspect(prods)
  defp format_execution_value(value) when is_map(value), do: inspect(value)
  defp format_execution_value(value), do: inspect(value)

  defp format_output(nil), do: "No output"

  defp format_output(%{"productions" => productions}) when is_list(productions) do
    productions
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
  end

  defp format_output(output) when is_map(output) do
    inspect(output, pretty: true, limit: 50)
  end

  defp format_output(output), do: inspect(output)

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when is_number(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 2)}s"
  defp format_duration(_), do: "-"

  defp get_duration_from_stats(nil), do: nil
  defp get_duration_from_stats(%{"total_duration_ms" => ms}), do: ms
  defp get_duration_from_stats(%{total_duration_ms: ms}), do: ms
  defp get_duration_from_stats(_), do: nil

  defp get_generation(nil), do: 0
  defp get_generation(%{"generation" => gen}), do: gen
  defp get_generation(%{generation: gen}), do: gen
  defp get_generation(_), do: 0

  defp format_relative_time(nil), do: "-"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> formatted_timestamp(datetime)
    end
  end
end
