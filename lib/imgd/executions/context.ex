defmodule Imgd.Executions.Context do
  @moduledoc """
  Runtime context available to nodes during execution.

  This is how data flows between nodes via expressions like `{{ $node["HTTP"].json }}`.
  The context accumulates outputs from each node as the workflow executes.
  """

  alias Imgd.Executions.Execution

  defstruct [
    :execution_id,
    :workflow_id,
    :workflow_version_id,
    :trigger_type,
    :trigger_data,
    :node_outputs,
    :variables,
    :current_node_id,
    :current_input,
    :metadata
  ]

  @type t :: %__MODULE__{
          execution_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          workflow_version_id: Ecto.UUID.t(),
          trigger_type: Execution.trigger_type(),
          trigger_data: map(),
          node_outputs: %{String.t() => term()},
          variables: map(),
          current_node_id: String.t() | nil,
          current_input: term(),
          metadata: map()
        }

  @doc """
  Creates a new context from an execution.

  The execution should have `workflow_version` preloaded if you need
  access to workflow-level variables from the version settings.

  ## Options
    * `:current_node_id` - the node currently being executed
    * `:current_input` - the input data for the current node
  """
  def new(%Execution{} = execution, opts \\ []) do
    current_node_id = Keyword.get(opts, :current_node_id)
    current_input = Keyword.get(opts, :current_input)

    %__MODULE__{
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_version_id: execution.workflow_version_id,
      trigger_type: Execution.trigger_type(execution),
      trigger_data: Execution.trigger_data(execution),
      node_outputs: execution.context || %{},
      variables: extract_variables(execution),
      current_node_id: current_node_id,
      current_input: current_input,
      metadata: %{
        started_at: execution.started_at,
        trace_id: get_in_metadata(execution, :trace_id),
        correlation_id: get_in_metadata(execution, :correlation_id)
      }
    }
  end

  @doc """
  Stores a node's output in the context.
  """
  def put_output(%__MODULE__{} = ctx, node_id, output) do
    %{ctx | node_outputs: Map.put(ctx.node_outputs, node_id, output)}
  end

  @doc """
  Retrieves a node's output from the context.
  """
  def get_output(%__MODULE__{node_outputs: outputs}, node_id) do
    Map.get(outputs, node_id)
  end

  @doc """
  Retrieves a node's output, raising if not found.
  """
  def get_output!(%__MODULE__{node_outputs: outputs}, node_id) do
    case Map.fetch(outputs, node_id) do
      {:ok, output} -> output
      :error -> raise KeyError, key: node_id, term: outputs
    end
  end

  @doc """
  Updates the current node being executed.
  """
  def set_current_node(%__MODULE__{} = ctx, node_id, input \\ nil) do
    %{ctx | current_node_id: node_id, current_input: input}
  end

  @doc """
  Gets a workflow variable by name.
  """
  def get_variable(%__MODULE__{variables: vars}, name) do
    Map.get(vars, name) || Map.get(vars, to_string(name))
  end

  @doc """
  Returns all node IDs that have outputs in the context.
  """
  def completed_nodes(%__MODULE__{node_outputs: outputs}) do
    Map.keys(outputs)
  end

  @doc """
  Checks if a node has been executed (has output in context).
  """
  def node_completed?(%__MODULE__{node_outputs: outputs}, node_id) do
    Map.has_key?(outputs, node_id)
  end

  # Private helpers

  defp extract_variables(%Execution{} = execution) do
    case execution.workflow_version do
      %{settings: settings} when is_map(settings) ->
        Map.get(settings, "variables") || Map.get(settings, :variables) || %{}
      _ ->
        %{}
    end
  end

  defp get_in_metadata(%Execution{metadata: nil}, _key), do: nil
  defp get_in_metadata(%Execution{metadata: meta}, key) do
    Map.get(meta, key)
  end
end
