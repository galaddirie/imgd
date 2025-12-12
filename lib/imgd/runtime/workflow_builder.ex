defmodule Imgd.Runtime.WorkflowBuilder do
  @moduledoc """
  Converts a WorkflowVersion into a Runic.Workflow.

  This module handles:
  - Parsing nodes and connections into a DAG structure
  - Topologically sorting nodes to determine execution order
  - Creating Runic steps that wrap NodeExecutor.execute/3 calls
  - Wiring up data flow via Runic's parent/child dependencies
  - Handling fan-out/fan-in for parallel branches
  - Installing observability hooks

  ## Usage

      {:ok, runic_workflow} = WorkflowBuilder.build(workflow_version, context)

  The resulting Runic workflow can then be executed via:

      workflow = Runic.Workflow.react_until_satisfied(runic_workflow, trigger_input)
  """

  require Runic
  alias Runic.Workflow
  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Executions.Context
  alias Imgd.Runtime.NodeExecutor
  alias Imgd.Runtime.Expression.Evaluator
  # Instrumentation is used via telemetry events

  @type build_result :: {:ok, Workflow.t()} | {:error, term()}

  @doc """
  Builds a Runic workflow from a WorkflowVersion.

  ## Parameters

  - `version` - The WorkflowVersion containing nodes and connections
  - `context` - The execution context for resolving expressions and variables

  ## Returns

  - `{:ok, workflow}` - Successfully built Runic workflow
  - `{:error, reason}` - Failed to build workflow
  """
  @spec build(WorkflowVersion.t(), Context.t()) :: build_result()
  def build(%WorkflowVersion{} = version, %Context{} = context) do
    with {:ok, graph} <- build_dag(version.nodes, version.connections),
         {:ok, sorted_nodes} <- topological_sort(graph, version.nodes),
         {:ok, workflow} <- build_runic_workflow(sorted_nodes, graph, context, version) do
      {:ok, workflow}
    end
  end

  @doc """
  Builds a Runic workflow or raises on error.
  """
  @spec build!(WorkflowVersion.t(), Context.t()) :: Workflow.t()
  def build!(%WorkflowVersion{} = version, %Context{} = context) do
    case build(version, context) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise "Failed to build workflow: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # DAG Construction
  # ============================================================================

  @doc false
  def build_dag(nodes, connections) do
    # Build adjacency list: %{source_node_id => [target_node_ids]}
    # And reverse adjacency: %{target_node_id => [source_node_ids]}
    node_ids = MapSet.new(nodes, & &1.id)

    # Validate all connections reference existing nodes
    invalid_connections =
      Enum.filter(connections, fn conn ->
        not MapSet.member?(node_ids, conn.source_node_id) or
          not MapSet.member?(node_ids, conn.target_node_id)
      end)

    if invalid_connections != [] do
      {:error, {:invalid_connections, invalid_connections}}
    else
      adjacency =
        Enum.reduce(connections, %{}, fn conn, acc ->
          Map.update(acc, conn.source_node_id, [conn.target_node_id], &[conn.target_node_id | &1])
        end)

      reverse_adjacency =
        Enum.reduce(connections, %{}, fn conn, acc ->
          Map.update(acc, conn.target_node_id, [conn.source_node_id], &[conn.source_node_id | &1])
        end)

      # Index connections by source for output routing
      connections_by_source =
        Enum.group_by(connections, & &1.source_node_id)

      {:ok,
       %{
         adjacency: adjacency,
         reverse_adjacency: reverse_adjacency,
         connections: connections,
         connections_by_source: connections_by_source,
         node_ids: node_ids
       }}
    end
  end

  @doc false
  def topological_sort(graph, nodes) do
    node_map = Map.new(nodes, &{&1.id, &1})

    # Calculate in-degrees
    in_degrees =
      Enum.reduce(nodes, %{}, fn node, acc ->
        parents = Map.get(graph.reverse_adjacency, node.id, [])
        Map.put(acc, node.id, length(parents))
      end)

    # Find nodes with no incoming edges (roots/triggers)
    queue =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    do_topological_sort(queue, in_degrees, graph.adjacency, node_map, [])
  end

  defp do_topological_sort([], in_degrees, _adjacency, _node_map, sorted) do
    # Check for cycles - if any nodes still have in_degree > 0, there's a cycle
    remaining = Enum.filter(in_degrees, fn {_id, degree} -> degree > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, {:cycle_detected, Enum.map(remaining, fn {id, _} -> id end)}}
    end
  end

  defp do_topological_sort([node_id | rest], in_degrees, adjacency, node_map, sorted) do
    node = Map.fetch!(node_map, node_id)
    children = Map.get(adjacency, node_id, [])

    # Decrement in-degree for all children
    {new_in_degrees, new_queue_additions} =
      Enum.reduce(children, {in_degrees, []}, fn child_id, {degrees, additions} ->
        new_degree = Map.get(degrees, child_id, 0) - 1
        new_degrees = Map.put(degrees, child_id, new_degree)

        if new_degree == 0 do
          {new_degrees, [child_id | additions]}
        else
          {new_degrees, additions}
        end
      end)

    # Remove processed node from in_degrees
    new_in_degrees = Map.delete(new_in_degrees, node_id)

    do_topological_sort(
      rest ++ new_queue_additions,
      new_in_degrees,
      adjacency,
      node_map,
      [node | sorted]
    )
  end

  # ============================================================================
  # Runic Workflow Construction
  # ============================================================================

  defp build_runic_workflow(sorted_nodes, graph, context, version) do
    # Create base workflow with name
    base_workflow =
      Runic.workflow(name: "workflow_#{version.workflow_id}_v#{version.version_tag}")

    # Build a map of node_id -> Runic step for wiring dependencies
    {workflow, step_map} =
      Enum.reduce(sorted_nodes, {base_workflow, %{}}, fn node, {wf, steps} ->
        step = create_runic_step(node, context)
        parents = Map.get(graph.reverse_adjacency, node.id, [])

        wf =
          case parents do
            [] ->
              # Root node - add directly to workflow
              Workflow.add_step(wf, step)

            [single_parent] ->
              # Single parent - add as child
              parent_step = Map.fetch!(steps, single_parent)
              Workflow.add_step(wf, parent_step, step)

            multiple_parents ->
              # Multiple parents - need a Join
              parent_steps = Enum.map(multiple_parents, &Map.fetch!(steps, &1))
              add_with_join(wf, parent_steps, step)
          end

        {wf, Map.put(steps, node.id, step)}
      end)

    # Install observability hooks
    workflow = install_hooks(workflow, step_map, context)

    {:ok, workflow}
  rescue
    e ->
      {:error, {:build_failed, Exception.message(e)}}
  end

  defp create_runic_step(%Node{} = node, %Context{} = context) do
    # Create a step that wraps the NodeExecutor
    Runic.step(
      name: String.to_atom(node.id),
      work: fn input ->
        execute_node(node, input, context)
      end
    )
  end

  defp execute_node(%Node{} = node, input, %Context{} = context) do
    # Update context with current node info
    ctx = Context.set_current_node(context, node.id, input)

    # Resolve expressions in config
    case Evaluator.resolve_config(node.config, ctx) do
      {:ok, resolved_config} ->
        # Execute via NodeExecutor behaviour
        case NodeExecutor.execute(node.type_id, resolved_config, input, ctx) do
          {:ok, output} ->
            output

          {:error, reason} ->
            # Wrap error to propagate through Runic
            raise Imgd.Runtime.NodeExecutionError,
              node_id: node.id,
              node_type_id: node.type_id,
              reason: reason

          {:skip, reason} ->
            # Return a skip marker that the runner can detect
            {:__skipped__, node.id, reason}
        end

      {:error, reason} ->
        raise Imgd.Runtime.NodeExecutionError,
          node_id: node.id,
          node_type_id: node.type_id,
          reason: {:expression_error, reason}
    end
  end

  defp add_with_join(workflow, parent_steps, child_step) do
    # Runic handles joins implicitly when a step has multiple parents
    # We add the step with all parents listed
    Enum.reduce(parent_steps, workflow, fn parent, wf ->
      Workflow.add_step(wf, parent, child_step)
    end)
  end

  # ============================================================================
  # Observability Hooks
  # ============================================================================

  defp install_hooks(workflow, step_map, context) do
    # Install before/after hooks for each step to emit telemetry
    Enum.reduce(step_map, workflow, fn {node_id, _step}, wf ->
      step_name = String.to_atom(node_id)

      wf
      |> Workflow.attach_before_hook(step_name, fn _step, workflow, _fact ->
        emit_node_started(context, node_id)
        workflow
      end)
      |> Workflow.attach_after_hook(step_name, fn _step, workflow, _fact ->
        emit_node_completed(context, node_id)
        workflow
      end)
    end)
  end

  defp emit_node_started(context, node_id) do
    :telemetry.execute(
      [:imgd, :engine, :node, :start],
      %{system_time: System.system_time(), queue_time_ms: nil},
      %{
        execution_id: context.execution_id,
        workflow_id: context.workflow_id,
        workflow_version_id: context.workflow_version_id,
        node_id: node_id,
        node_type_id: "unknown",
        attempt: 1
      }
    )
  end

  defp emit_node_completed(context, node_id) do
    :telemetry.execute(
      [:imgd, :engine, :node, :stop],
      %{duration_ms: 0},
      %{
        execution_id: context.execution_id,
        workflow_id: context.workflow_id,
        workflow_version_id: context.workflow_version_id,
        node_id: node_id,
        node_type_id: "unknown",
        attempt: 1,
        status: :completed
      }
    )
  end
end

defmodule Imgd.Runtime.NodeExecutionError do
  @moduledoc """
  Exception raised when a node execution fails.
  """
  defexception [:node_id, :node_type_id, :reason]

  @impl true
  def message(%{node_id: node_id, node_type_id: type_id, reason: reason}) do
    "Node #{node_id} (#{type_id}) failed: #{inspect(reason)}"
  end
end
