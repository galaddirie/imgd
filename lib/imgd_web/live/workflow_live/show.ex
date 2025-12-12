defmodule ImgdWeb.WorkflowLive.Show do
  @moduledoc """
  LiveView for showing workflow details and execution history.
  """
  use ImgdWeb, :live_view

  alias Imgd.Workflows
  alias Imgd.Executions
  import ImgdWeb.Formatters, except: [trigger_label: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    try do
      workflow = Workflows.get_workflow!(scope, id)
      executions = Executions.list_executions(scope, workflow: workflow, limit: 10)


      socket =
        socket
        |> assign(:page_title, workflow.name)
        |> assign(:workflow, workflow)
        |> assign(:executions, executions)

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





  defp workflow_input_schema(workflow) do
    workflow.settings[:input_schema] || workflow.settings["input_schema"]
  end

  defp node_schemas(workflow) do
    workflow.settings[:node_schemas] || workflow.settings["node_schemas"]
  end

  defp render_schema(nil), do: "Not provided"

  defp render_schema(schema) do
    inspect(schema, pretty: true, limit: :infinity, printable_limit: :infinity)
  rescue
    _ -> "Unable to render schema"
  end

  defp render_workflow_definition(workflow) do
    # Simply render the nodes and connections as JSON-like structure
    %{
      nodes: workflow.nodes,
      connections: workflow.connections,
      triggers: workflow.triggers,
      settings: workflow.settings
    }
    |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  defp trigger_label(workflow) do
    case workflow.triggers do
      [trigger | _] ->
        trigger.type
        |> to_string()
        |> String.capitalize()

      _ ->
        "Manual"
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
                <span :if={@workflow.current_version_tag} class="badge badge-ghost badge-xs">v{@workflow.current_version_tag}</span>
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
                      <th>Actions</th>
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
                          {format_execution_value(execution.trigger && execution.trigger.data)}
                        </td>
                        <td class="max-w-48 truncate text-xs">
                          {format_execution_value(execution.output)}
                        </td>
                        <td class="text-xs">
                          {format_duration(execution_duration_ms(execution))}
                        </td>
                        <td class="text-xs text-base-content/60">
                          {format_relative_time(execution.started_at)}
                        </td>
                        <td>
                          <.link
                            navigate={~p"/workflows/#{@workflow.id}/executions/#{execution.id}"}
                            class="btn btn-ghost btn-xs"
                            title="Inspect execution"
                          >
                            <.icon name="hero-eye" class="size-4" />
                          </.link>
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
                    <span class="text-sm">{@workflow.current_version_tag || "Unversioned"}</span>
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

        <%!-- Workflow Definition Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <div class="flex items-center gap-2 mb-4">
              <.icon name="hero-code-bracket" class="size-5" />
              <h2 class="text-lg font-semibold text-base-content">Workflow Definition</h2>
            </div>

            <div>
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
                Parsed Elixir Code
              </p>
              <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap min-h-[200px]">
                <code><%= render_workflow_definition(@workflow) %></code>
              </pre>
            </div>
          </div>
        </section>

        <%!-- Workflow Schemas Section --%>
        <section>
          <div class="card border border-base-300 rounded-2xl shadow-sm bg-base-100 p-6">
            <div class="flex items-center gap-2 mb-4">
              <.icon name="hero-brackets-curly" class="size-5" />
              <h2 class="text-lg font-semibold text-base-content">Schemas</h2>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
                  Input Schema
                </p>
                <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap min-h-[120px]">
                  <code><%= render_schema(workflow_input_schema(@workflow)) %></code>
                </pre>
              </div>

              <div>
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
                  Node Schemas
                </p>
                <pre class="rounded-xl bg-base-200/60 p-3 text-xs font-mono text-base-content/90 shadow-inner whitespace-pre-wrap min-h-[120px]">
                  <code><%= render_schema(node_schemas(@workflow)) %></code>
                </pre>
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


  defp format_duration(nil), do: "-"
  defp format_duration(ms) when is_number(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 2)}s"

  # Copied from execution_show.ex to ensure consistent duration calculation
  defp execution_duration_ms(%{started_at: started, completed_at: completed})
       when not is_nil(started) and not is_nil(completed) do
    DateTime.diff(completed, started, :millisecond)
  end

  defp execution_duration_ms(_), do: nil

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
