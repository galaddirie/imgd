defmodule Imgd.Runtime.ExecutionState do
  @moduledoc """
  Execution-scoped ephemeral storage using a single ETS table.

  This is the **single source of truth** for all runtime execution state.
  It stores node outputs, timing information, current node context, and
  node execution records during workflow execution.

  Keys are tuples: {execution_id, type, ...}.

  ## Stored Data

  - Node outputs: `{execution_id, :output, node_id}` → output data
  - Start times: `{execution_id, :start_time, node_id}` → monotonic time
  - Node executions: `{execution_id, :node_execution, node_id}` → NodeExecution struct
  - Current node: `{execution_id, :current_node}` → {node_id, input}

  ## Usage

      # Initialize for an execution
      ExecutionState.start(execution_id)

      # Record node output (called after each node completes)
      ExecutionState.record_output(execution_id, "node_1", %{result: "value"})

      # Set current node context (called before expression evaluation)
      ExecutionState.set_current_node(execution_id, "node_2", input_data)

      # Get all outputs for expression evaluation
      outputs = ExecutionState.outputs(execution_id)

      # Cleanup when execution finishes
      ExecutionState.cleanup(execution_id)
  """

  @table __MODULE__

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link do
    create_table()
    # The table is owned by the supervisor process; no worker process needed.
    :ignore
  end

  @spec start(Ecto.UUID.t()) :: :ok
  def start(execution_id) do
    cleanup(execution_id)
  end

  # ===========================================================================
  # Node Outputs
  # ===========================================================================

  @spec record_output(Ecto.UUID.t(), String.t(), term()) :: :ok
  def record_output(execution_id, node_id, output) do
    true = :ets.insert(@table, {{execution_id, :output, node_id}, output})
    :ok
  end

  @spec outputs(Ecto.UUID.t()) :: map()
  def outputs(execution_id) do
    @table
    |> :ets.match({{execution_id, :output, :"$1"}, :"$2"})
    |> Map.new(fn [node_id, output] -> {node_id, output} end)
  end

  @spec get_output(Ecto.UUID.t(), String.t()) :: {:ok, term()} | :error
  def get_output(execution_id, node_id) do
    case :ets.lookup(@table, {execution_id, :output, node_id}) do
      [{{^execution_id, :output, ^node_id}, output}] -> {:ok, output}
      _ -> :error
    end
  end

  # ===========================================================================
  # Current Node Context (for expression evaluation)
  # ===========================================================================

  @spec set_current_node(Ecto.UUID.t(), String.t(), term()) :: :ok
  def set_current_node(execution_id, node_id, input) do
    true = :ets.insert(@table, {{execution_id, :current_node}, {node_id, input}})
    :ok
  end

  @spec current_node(Ecto.UUID.t()) :: {String.t(), term()} | nil
  def current_node(execution_id) do
    case :ets.lookup(@table, {execution_id, :current_node}) do
      [{{^execution_id, :current_node}, value}] -> value
      _ -> nil
    end
  end

  @spec current_input(Ecto.UUID.t()) :: term() | nil
  def current_input(execution_id) do
    case current_node(execution_id) do
      {_node_id, input} -> input
      nil -> nil
    end
  end

  # ===========================================================================
  # Timing
  # ===========================================================================

  @spec record_start_time(Ecto.UUID.t(), String.t(), non_neg_integer()) :: :ok
  def record_start_time(execution_id, node_id, start_time_ms) do
    true = :ets.insert(@table, {{execution_id, :start_time, node_id}, start_time_ms})
    :ok
  end

  @spec fetch_start_time(Ecto.UUID.t(), String.t()) :: {:ok, non_neg_integer()} | :error
  def fetch_start_time(execution_id, node_id) do
    case :ets.lookup(@table, {execution_id, :start_time, node_id}) do
      [{{^execution_id, :start_time, ^node_id}, value}] -> {:ok, value}
      _ -> :error
    end
  end

  # ===========================================================================
  # Node Executions
  # ===========================================================================

  @spec put_node_execution(Ecto.UUID.t(), String.t(), Imgd.Executions.NodeExecution.t()) :: :ok
  def put_node_execution(execution_id, node_id, %Imgd.Executions.NodeExecution{} = node_exec) do
    true = :ets.insert(@table, {{execution_id, :node_execution, node_id}, node_exec})
    :ok
  end

  @spec fetch_node_execution(Ecto.UUID.t(), String.t()) ::
          {:ok, Imgd.Executions.NodeExecution.t()} | :error
  def fetch_node_execution(execution_id, node_id) do
    case :ets.lookup(@table, {execution_id, :node_execution, node_id}) do
      [{{^execution_id, :node_execution, ^node_id}, value}] -> {:ok, value}
      _ -> :error
    end
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @spec cleanup(Ecto.UUID.t()) :: :ok
  def cleanup(execution_id) do
    :ets.match_delete(@table, {{execution_id, :_, :_}, :_})
    :ets.match_delete(@table, {{execution_id, :current_node}, :_})
    :ok
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end
end
