defmodule Imgd.Runtime.Core.NodeRunner do
  @moduledoc """
  Pure execution of a single workflow node.

  Responsibilities:
  1. Resolve node configuration using Expression evaluator.
  2. Resolve executor module for the node type.
  3. Execute the node.
  4. Normalize output.
  """

  alias Imgd.Nodes.Executors.Behaviour, as: NodeExecutor
  alias Imgd.Runtime.Core.Expression
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Executions.Execution

  @type result ::
          {:ok, output :: term()}
          | {:error, reason :: term()}
          | {:skip, reason :: term()}

  @doc """
  Runs a node in isolation.

  ## Parameters
  - `node`: The definition of the node to run.
  - `input`: The input data arriving at the node (merged from parents).
  - `context_or_fun`: The variable context for expression evaluation (can be a map or lazy function).
  - `execution`: The Execution struct (passed to executor for metadata).
  """
  @spec run(Node.t(), term(), map() | (-> map()), Execution.t()) :: result()
  def run(%Node{} = node, input, context_or_fun, %Execution{} = execution) do
    # 1. Resolve configuration
    with {:ok, resolved_config} <- resolve_config(node.config, context_or_fun),
         # 2. Execute
         {:ok, output} <- execute_node(node.type_id, resolved_config, input, execution) do
      {:ok, output}
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
      {:executor_not_found, reason} -> {:error, {:executor_not_found, reason}}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason ->
      {:error, {:caught, kind, reason}}
  end

  defp resolve_config(config, context_or_fun) do
    # Only materialize context if config actually has expressions
    if has_expressions?(config) do
      context = if is_function(context_or_fun), do: context_or_fun.(), else: context_or_fun
      Expression.evaluate(config, context)
    else
      {:ok, config}
    end
  end

  # Check if config contains expressions that need evaluation
  defp has_expressions?(config) when is_binary(config) do
    String.contains?(config, "{{") or String.contains?(config, "{%")
  end

  defp has_expressions?(config) when is_map(config) do
    Enum.any?(config, fn {_k, v} -> has_expressions?(v) end)
  end

  defp has_expressions?(config) when is_list(config) do
    Enum.any?(config, &has_expressions?/1)
  end

  defp has_expressions?(_), do: false

  defp execute_node(type_id, config, input, execution) do
    NodeExecutor.execute(type_id, config, input, execution)
  end
end
