defmodule Imgd.Collaboration.PreviewExecution do
  @moduledoc """
  Builds and runs preview executions that incorporate editor state
  (pins, disabled nodes, partial execution).
  """

  alias Imgd.Collaboration.EditSession.Server, as: EditServer
  alias Imgd.Collaboration.EditorState
  alias Imgd.Graph
  alias Imgd.Runtime.RunicAdapter
  alias Imgd.Executions
  alias Imgd.Accounts.Scope

  @type execution_mode :: :full | :from_node | :to_node | :selected

  @type preview_opts :: [
    mode: execution_mode(),
    target_nodes: [String.t()],
    input_data: map()
  ]

  @doc """
  Run a preview execution with editor state applied.

  This:
  1. Gets current draft and editor state from the session
  2. Applies disabled nodes (skip or exclude)
  3. Injects pinned outputs
  4. Builds execution subgraph based on mode
  5. Runs the execution
  """
  @spec run(String.t(), Scope.t(), preview_opts()) ::
    {:ok, Executions.Execution.t()} | {:error, term()}
  def run(workflow_id, scope, opts \\ []) do
    mode = Keyword.get(opts, :mode, :full)
    target_nodes = Keyword.get(opts, :target_nodes, [])
    input_data = Keyword.get(opts, :input_data, %{})

    with {:ok, draft} <- get_draft(workflow_id),
         {:ok, editor_state} <- get_editor_state(workflow_id),
         {:ok, effective_draft} <- apply_editor_state(draft, editor_state, mode, target_nodes),
         {:ok, execution} <- create_preview_execution(workflow_id, scope, effective_draft, editor_state, input_data) do

      # Run synchronously for preview (could also queue)
      run_execution(execution, effective_draft, editor_state, scope)
    end
  end

  defp get_draft(workflow_id) do
    case Imgd.Workflows.get_draft(workflow_id) do
      {:error, :not_found} -> {:error, :draft_not_found}
      {:ok, draft} -> {:ok, draft}
    end
  end

  defp get_editor_state(workflow_id) do
    case EditServer.get_editor_state(workflow_id) do
      {:ok, state} -> {:ok, state}
      _ -> {:ok, %EditorState{workflow_id: workflow_id}}
    end
  end

  defp apply_editor_state(draft, editor_state, mode, target_nodes) do
    # 1. Remove or bypass disabled nodes
    nodes = apply_disabled_nodes(draft.nodes, editor_state)

    # 2. Filter connections for remaining nodes
    node_ids = MapSet.new(Enum.map(nodes, & &1.id))
    connections = Enum.filter(draft.connections, fn conn ->
      MapSet.member?(node_ids, conn.source_node_id) and
      MapSet.member?(node_ids, conn.target_node_id)
    end)

    # 3. Build subgraph based on execution mode
    {nodes, connections} = build_subgraph(nodes, connections, mode, target_nodes)

    {:ok, %{draft | nodes: nodes, connections: connections}}
  end

  defp apply_disabled_nodes(nodes, editor_state) do
    # For now, just exclude disabled nodes entirely
    # Could implement bypass mode here
    Enum.reject(nodes, fn node ->
      MapSet.member?(editor_state.disabled_nodes, node.id)
    end)
  end

  defp build_subgraph(nodes, connections, :full, _targets) do
    {nodes, connections}
  end

  defp build_subgraph(nodes, connections, :from_node, [target_id]) do
    graph = Graph.from_workflow!(nodes, connections)
    downstream = Graph.downstream(graph, target_id)
    keep_ids = MapSet.new([target_id | downstream])

    filtered_nodes = Enum.filter(nodes, &MapSet.member?(keep_ids, &1.id))
    filtered_connections = Enum.filter(connections, fn conn ->
      MapSet.member?(keep_ids, conn.source_node_id) and
      MapSet.member?(keep_ids, conn.target_node_id)
    end)

    {filtered_nodes, filtered_connections}
  end

  defp build_subgraph(nodes, connections, :to_node, [target_id]) do
    graph = Graph.from_workflow!(nodes, connections)
    upstream = Graph.upstream(graph, target_id)
    keep_ids = MapSet.new([target_id | upstream])

    filtered_nodes = Enum.filter(nodes, &MapSet.member?(keep_ids, &1.id))
    filtered_connections = Enum.filter(connections, fn conn ->
      MapSet.member?(keep_ids, conn.source_node_id) and
      MapSet.member?(keep_ids, conn.target_node_id)
    end)

    {filtered_nodes, filtered_connections}
  end

  defp build_subgraph(nodes, connections, :selected, target_ids) do
    keep_ids = MapSet.new(target_ids)

    filtered_nodes = Enum.filter(nodes, &MapSet.member?(keep_ids, &1.id))
    filtered_connections = Enum.filter(connections, fn conn ->
      MapSet.member?(keep_ids, conn.source_node_id) and
      MapSet.member?(keep_ids, conn.target_node_id)
    end)

    {filtered_nodes, filtered_connections}
  end

  defp create_preview_execution(workflow_id, scope, _draft, editor_state, input_data) do
    # Include pinned outputs in the execution context
    initial_context =
      editor_state.pinned_outputs
      |> Enum.into(%{}, fn {node_id, data} -> {node_id, data} end)

    Executions.create_execution(%{
      workflow_id: workflow_id,
      execution_type: :preview,
      trigger: %{type: :manual, data: input_data},
      context: initial_context,
      triggered_by_user_id: scope.user.id,
      metadata: %{
        preview: true,
        pinned_nodes: Map.keys(editor_state.pinned_outputs),
        disabled_nodes: MapSet.to_list(editor_state.disabled_nodes)
      }
    }, scope)
  end

  defp run_execution(execution, draft, editor_state, scope) do
    # Build Runic workflow with pinned outputs injected
    runic_workflow = RunicAdapter.to_runic_workflow(draft,
      execution_id: execution.id,
      pinned_outputs: editor_state.pinned_outputs
    )

    # Execute synchronously for preview
    case Runic.Workflow.react_until_satisfied(runic_workflow, %{}) do
      result_workflow ->
        context = extract_context(result_workflow)
        Executions.update_execution_status(execution, :completed, scope, output: context)
        {:ok, execution}
    end
  rescue
    e ->
      Executions.update_execution_status(execution, :failed, scope, error: Exception.message(e))
      {:error, e}
  end

  defp extract_context(_workflow) do
    # Extract node outputs from Runic workflow
    # (Implementation depends on Runic internals)
    %{}
  end
end
