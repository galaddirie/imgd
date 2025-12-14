defmodule Imgd.Runtime.ExecutionState do
  @moduledoc """
  Execution-scoped storage for workflow runtime data.

  Stores node outputs and timing metadata in a shared ETS table keyed by the
  execution ID so data remains available across processes without relying on
  the process dictionary.
  """

  @table :imgd_execution_state

  @spec start(Ecto.UUID.t()) :: :ok
  def start(execution_id) do
    ensure_table!()
    cleanup(execution_id)
  end

  @spec record_output(Ecto.UUID.t(), String.t(), term()) :: :ok
  def record_output(execution_id, node_id, output) do
    ensure_table!()
    true = :ets.insert(@table, {{execution_id, :output, node_id}, output})
    :ok
  end

  @spec outputs(Ecto.UUID.t()) :: map()
  def outputs(execution_id) do
    ensure_table!()

    :ets.select(@table, [
      {{{:"$1", :output, :"$2"}, :"$3"}, [{:==, :"$1", execution_id}], [{{:"$2", :"$3"}}]}
    ])
    |> Map.new()
  end

  @spec record_start_time(Ecto.UUID.t(), String.t(), non_neg_integer()) :: :ok
  def record_start_time(execution_id, node_id, start_time_ms) do
    ensure_table!()
    true = :ets.insert(@table, {{execution_id, :start_time, node_id}, start_time_ms})
    :ok
  end

  @spec put_node_execution(Ecto.UUID.t(), String.t(), Imgd.Executions.NodeExecution.t()) :: :ok
  def put_node_execution(execution_id, node_id, %Imgd.Executions.NodeExecution{} = node_exec) do
    ensure_table!()
    true = :ets.insert(@table, {{execution_id, :node_execution, node_id}, node_exec})
    :ok
  end

  @spec fetch_node_execution(Ecto.UUID.t(), String.t()) ::
          {:ok, Imgd.Executions.NodeExecution.t()} | :error
  def fetch_node_execution(execution_id, node_id) do
    ensure_table!()

    case :ets.lookup(@table, {execution_id, :node_execution, node_id}) do
      [{{^execution_id, :node_execution, ^node_id}, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec fetch_start_time(Ecto.UUID.t(), String.t()) :: {:ok, non_neg_integer()} | :error
  def fetch_start_time(execution_id, node_id) do
    ensure_table!()

    case :ets.lookup(@table, {execution_id, :start_time, node_id}) do
      [{{^execution_id, :start_time, ^node_id}, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec cleanup(Ecto.UUID.t()) :: :ok
  def cleanup(execution_id) do
    if table_created?() do
      :ets.match_delete(@table, {execution_id, :_, :_})
    end

    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ok
        rescue
          ArgumentError ->
            :ok
        end

      _table ->
        :ok
    end
  end

  defp table_created?, do: :ets.whereis(@table) != :undefined
end
