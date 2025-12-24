defmodule Imgd.Runtime.Nodes.NodeStep do
  @moduledoc """
  Creates Runic Steps from Imgd workflow nodes.

  This module bridges Imgd's node system with Runic's step-based execution.
  It handles:
  - Expression evaluation in node configs before execution
  - Building execution context from Runic workflow state
  - Error handling with controlled throws for proper error propagation

  ## Usage

      node = %Imgd.Workflows.Embeds.Node{id: "node_1", type_id: "debug", config: %{}}
      step = NodeStep.create(node, execution_id: "exec_123")

      # The step can then be added to a Runic workflow
      Workflow.add(workflow, step)
  """

  require Runic
  alias Imgd.Runtime.ExecutionContext
  alias Imgd.Runtime.Expression
  alias Imgd.Nodes.Executors.Behaviour, as: ExecutorBehaviour

  @type workflow_node :: Imgd.Workflows.Embeds.Node.t()
  @type step_opts :: [
          execution_id: String.t(),
          workflow_id: String.t(),
          variables: map(),
          metadata: map()
        ]

  @doc """
  Creates a Runic step from an Imgd node.

  The step wraps the node's executor and handles:
  - Building context from the Runic fact input
  - Evaluating expressions in the node's config
  - Executing the node via its registered executor
  - Error handling with controlled throws

  ## Options

  - `:execution_id` - The Imgd Execution record ID
  - `:workflow_id` - The source workflow ID
  - `:variables` - Workflow-level variables for expression evaluation
  - `:metadata` - Execution metadata
  """
  @spec create(workflow_node(), step_opts()) :: Runic.Workflow.Step.t()
  def create(node, opts \\ []) do
    # Capture node and opts in the closure
    # Runic will call this function with the input from parent steps

    # Determine execution target
    # Priority: Node Config > Workflow Default (via opts) > Local
    target = determine_compute_target(node, opts)

    step =
      Runic.step(
        fn input ->
          # Dispatch execution to the target
          # We pass the MFA: {NodeStep, :execute_with_context, [node, input, opts]}
          case Imgd.Compute.run(target, __MODULE__, :execute_with_context, [node, input, opts]) do
            {:ok, result} ->
              result

            {:error, {:throw, reason}} ->
              # Propagate thrown errors (e.g. from ClusterNode catch)
              throw(reason)

            {:error, reason} ->
              # Wrap other errors (e.g. RPC failure)
              throw({:node_error, node.id, {:compute_error, reason}})
          end
        end,
        name: node.id
      )

    # Ensure unique hash for programmatic steps to avoid graph vertex collisions
    # We use phash2 on the combination of the original hash and the node id
    unique_hash = :erlang.phash2({step.hash, node.id}, 4_294_967_296)
    %{step | hash: unique_hash}
  end

  defp determine_compute_target(node, opts) do
    # check node config first
    node_config_target = Map.get(node.config, "compute")

    if node_config_target do
      Imgd.Compute.Target.parse(node_config_target)
    else
      # check workflow default
      Keyword.get(opts, :default_compute, Imgd.Compute.Target.local())
    end
  end

  @doc """
  Executes a node with full context building and expression evaluation.

  This is the core execution logic that:
  1. Builds an ExecutionContext from the input
  2. Evaluates expressions in the node's config
  3. Calls the node's executor
  4. Handles errors appropriately
  """
  @spec execute_with_context(workflow_node(), term(), step_opts()) :: term()
  def execute_with_context(node, input, opts) do
    # Build context from options and input
    ctx = build_context(node, input, opts)

    # Evaluate expressions in the config
    evaluated_config =
      case evaluate_config(node.config, ctx) do
        {:ok, config} -> config
        {:error, reason} -> throw({:node_error, node.id, {:expression_error, reason}})
      end

    # Resolve and execute the node
    executor = ExecutorBehaviour.resolve!(node.type_id)

    case executor.execute(evaluated_config, input, ctx) do
      {:ok, result} ->
        result

      {:error, reason} ->
        throw({:node_error, node.id, reason})

      {:skip, _reason} ->
        # Skip produces nil, which Runic will handle appropriately
        nil
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_context(node, input, opts) do
    ExecutionContext.new(
      execution_id: Keyword.get(opts, :execution_id),
      workflow_id: Keyword.get(opts, :workflow_id),
      node_id: node.id,
      variables: Keyword.get(opts, :variables, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      input: input,
      node_outputs: Keyword.get(opts, :node_outputs, %{})
    )
  end

  defp evaluate_config(config, ctx) when is_map(config) do
    # Build variables for expression evaluation
    vars = build_expression_vars(ctx)

    Expression.evaluate_deep(config, vars)
  end

  defp evaluate_config(config, _ctx), do: {:ok, config}

  defp build_expression_vars(ctx) do
    %{
      "json" => ctx.input,
      "nodes" => build_nodes_var(ctx.node_outputs),
      "execution" => %{
        "id" => ctx.execution_id
      },
      "workflow" => %{
        "id" => ctx.workflow_id
      },
      "variables" => ctx.variables,
      "metadata" => ctx.metadata
    }
  end

  defp build_nodes_var(node_outputs) when is_map(node_outputs) do
    # Transform node outputs into the nodes.NodeName.json format
    Map.new(node_outputs, fn {node_id, output} ->
      {node_id, %{"json" => output}}
    end)
  end

  defp build_nodes_var(_), do: %{}
end
