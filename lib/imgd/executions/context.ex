defmodule Imgd.Executions.Context do
  @moduledoc """
  Runtime context available to nodes during execution.
  This is how data flows between nodes via expressions like {{ $node["HTTP"].json }}.
  """

  defstruct [
    :execution_id,
    :workflow_name,
    :trigger_data,
    # %{"node_id" => output_data}
    :node_outputs,
    # Workflow-level variables
    :variables,

    :current_node_id,
    :current_input,
    :metadata
  ]

  @type t :: %__MODULE__{
          execution_id: integer(),
          workflow_name: String.t(),
          trigger_data: map(),
          node_outputs: map(),
          variables: map(),
          current_node_id: String.t(),
          current_input: term(),
          metadata: map()
        }

  def new(execution, current_node_id \\ nil, current_input \\ nil) do
    %__MODULE__{
      execution_id: execution.id,
      workflow_name: execution.definition.name,
      trigger_data: execution.trigger_data,
      node_outputs: execution.context,
      variables: Map.get(execution.definition.settings, "variables", %{}),
      current_node_id: current_node_id,
      current_input: current_input,
      metadata: %{
        started_at: execution.started_at,
        definition_version: execution.definition_version
      }
    }
  end

  def put_output(%__MODULE__{} = ctx, node_id, output) do
    %{ctx | node_outputs: Map.put(ctx.node_outputs, node_id, output)}
  end

  def get_output(%__MODULE__{node_outputs: outputs}, node_id) do
    Map.get(outputs, node_id)
  end
end
