defmodule Imgd.Runtime.ExecutionContext do
  @moduledoc """
  Rich context for node execution within a Runic workflow.

  This struct provides all the context a node executor needs, built from
  Runic's workflow state and fact ancestry.

  ## Fields

  - `:execution_id` - The Imgd Execution record ID
  - `:workflow_id` - The source workflow ID
  - `:node_id` - The current node being executed
  - `:node_outputs` - Map of node_id => output for all completed nodes
  - `:variables` - Workflow-level variables
  - `:metadata` - Execution metadata (trace_id, etc.)
  - `:input` - The input value for this node (from parent facts)
  """

  @type t :: %__MODULE__{
          execution_id: String.t() | nil,
          workflow_id: String.t() | nil,
          node_id: String.t() | nil,
          node_outputs: %{String.t() => term()},
          variables: map(),
          metadata: map(),
          input: term()
        }

  defstruct [
    :execution_id,
    :workflow_id,
    :node_id,
    node_outputs: %{},
    variables: %{},
    metadata: %{},
    input: nil
  ]

  @doc """
  Builds an ExecutionContext from Runic workflow state.

  Extracts node outputs by traversing the workflow's graph for `:produced` edges.
  """
  @spec from_runic_workflow(Runic.Workflow.t(), map()) :: t()
  def from_runic_workflow(workflow, opts \\ %{}) do
    node_outputs = extract_node_outputs(workflow)

    %__MODULE__{
      execution_id: Map.get(opts, :execution_id),
      workflow_id: Map.get(opts, :workflow_id),
      node_id: Map.get(opts, :node_id),
      node_outputs: node_outputs,
      variables: Map.get(opts, :variables, %{}),
      metadata: Map.get(opts, :metadata, %{}),
      input: Map.get(opts, :input)
    }
  end

  @doc """
  Creates a minimal context for testing or simple execution.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Updates the context with output from a completed node.
  """
  @spec put_output(t(), String.t(), term()) :: t()
  def put_output(%__MODULE__{} = ctx, node_id, output) do
    %{ctx | node_outputs: Map.put(ctx.node_outputs, node_id, output)}
  end

  @doc """
  Gets the output of a previously completed node.
  """
  @spec get_output(t(), String.t()) :: term() | nil
  def get_output(%__MODULE__{node_outputs: outputs}, node_id) do
    Map.get(outputs, node_id)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp extract_node_outputs(workflow) do
    graph = workflow.graph

    # Find all Facts with :produced edges from Steps
    graph
    |> Graph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Fact{}, &1))
    |> Enum.reduce(%{}, fn fact, acc ->
      producing_step =
        graph
        |> Graph.in_neighbors(fact)
        |> Enum.find(&match?(%Runic.Workflow.Step{}, &1))

      case producing_step do
        %{name: name} when is_binary(name) ->
          Map.put(acc, name, fact.value)

        _ ->
          acc
      end
    end)
  end
end
