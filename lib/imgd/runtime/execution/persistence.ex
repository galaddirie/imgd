defmodule Imgd.Runtime.Execution.Persistence do
  @moduledoc """
  Behaviour for persisting workflow execution state.
  Separates the runtime from database details.
  """

  alias Imgd.Executions.Execution
  alias Imgd.Executions.NodeExecution
  alias Imgd.Workflows.Embeds.Node

  @callback load_execution(id :: String.t()) :: {:ok, Execution.t()} | {:error, term()}

  @callback mark_running(id :: String.t()) :: {:ok, Execution.t()} | {:error, term()}

  @callback mark_completed(id :: String.t(), output :: map(), node_outputs :: map()) ::
              {:ok, Execution.t()} | {:error, term()}

  @callback mark_failed(id :: String.t(), reason :: term()) ::
              {:ok, Execution.t()} | {:error, term()}

  @callback record_node_start(execution_id :: String.t(), node :: Node.t(), input :: term()) ::
              {:ok, NodeExecution.t()} | {:error, term()}

  @callback record_node_finish(
              node_execution :: NodeExecution.t(),
              status :: :completed | :failed | :skipped,
              result_or_error :: term(),
              duration_ms :: non_neg_integer()
            ) :: {:ok, NodeExecution.t()} | {:error, term()}
end
