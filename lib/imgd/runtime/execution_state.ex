defmodule Imgd.Runtime.ExecutionState do
  @moduledoc """
  Execution-scoped ephemeral storage using a single ETS table.

  Keys are tuples: {execution_id, type, node_id}.
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

  @spec record_start_time(Ecto.UUID.t(), String.t(), non_neg_integer()) :: :ok
  def record_start_time(execution_id, node_id, start_time_ms) do
    true = :ets.insert(@table, {{execution_id, :start_time, node_id}, start_time_ms})
    :ok
  end

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

  @spec fetch_start_time(Ecto.UUID.t(), String.t()) :: {:ok, non_neg_integer()} | :error
  def fetch_start_time(execution_id, node_id) do
    case :ets.lookup(@table, {execution_id, :start_time, node_id}) do
      [{{^execution_id, :start_time, ^node_id}, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec cleanup(Ecto.UUID.t()) :: :ok
  def cleanup(execution_id) do
    :ets.match_delete(@table, {{execution_id, :_, :_}, :_})
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
