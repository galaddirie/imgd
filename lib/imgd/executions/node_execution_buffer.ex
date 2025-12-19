defmodule Imgd.Executions.NodeExecutionBuffer do
  @moduledoc """
  Buffers node execution writes so Runic hooks do not block on DB calls.

  Hooks enqueue start/complete events via `record/1`; this GenServer batches
  them into periodic `Repo.insert_all/3` upserts. The trade-off is eventual
  consistency—the database (and any consumers reading from it) may lag by up
  to `@flush_interval_ms`.
  """

  use GenServer
  require Logger

  alias Imgd.Executions.NodeExecution
  alias Imgd.Repo

  @flush_interval_ms 100
  @max_buffer_size 50

  @updatable_fields [
    :status,
    :input_data,
    :output_data,
    :error,
    :metadata,
    :queued_at,
    :started_at,
    :completed_at,
    :attempt,
    :retry_of_id,
    :updated_at
  ]

  @type state :: %{buffer: map(), timer_ref: reference() | nil}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Record a node execution change to be flushed asynchronously.
  """
  def record(%NodeExecution{} = node_exec) do
    if Application.get_env(:imgd, :sync_node_execution_buffer, false) do
      attrs = attrs_from_node_exec(node_exec)

      Repo.insert_all(NodeExecution, [attrs],
        on_conflict: {:replace, @updatable_fields},
        conflict_target: [:id]
      )
    else
      GenServer.cast(__MODULE__, {:record, node_exec})
    end
  end

  @doc """
  Force a buffer flush (useful in tests).
  """
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(_opts) do
    {:ok, %{buffer: %{}, timer_ref: schedule_flush()}}
  end

  @impl true
  def handle_cast({:record, %NodeExecution{} = node_exec}, %{buffer: buffer} = state) do
    attrs = attrs_from_node_exec(node_exec)
    key = buffer_key(attrs)

    buffer = Map.update(buffer, key, attrs, &merge_attrs(&1, attrs))
    state = %{state | buffer: buffer}

    {:noreply, maybe_flush(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = flush_buffer(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush_buffer(state)
    {:noreply, %{state | timer_ref: schedule_flush()}}
  end

  defp buffer_key(%{execution_id: execution_id, node_id: node_id, id: id}) do
    {execution_id, node_id, id}
  end

  defp attrs_from_node_exec(%NodeExecution{} = node_exec) do
    now = current_time()

    %{
      id: node_exec.id || Ecto.UUID.generate(),
      execution_id: node_exec.execution_id,
      node_id: node_exec.node_id,
      node_type_id: node_exec.node_type_id,
      status: node_exec.status,
      input_data: node_exec.input_data,
      output_data: node_exec.output_data,
      error: node_exec.error,
      metadata: node_exec.metadata || %{},
      queued_at: node_exec.queued_at,
      started_at: node_exec.started_at,
      completed_at: node_exec.completed_at,
      attempt: node_exec.attempt || 1,
      retry_of_id: node_exec.retry_of_id,
      inserted_at: node_exec.inserted_at || now,
      updated_at: now
    }
  end

  defp merge_attrs(existing, incoming) do
    Map.merge(existing, incoming, fn
      :inserted_at, old, new -> old || new
      _key, _old, new -> new
    end)
  end

  defp maybe_flush(%{buffer: buffer} = state) do
    if map_size(buffer) >= @max_buffer_size do
      flush_buffer(state)
    else
      state
    end
  end

  defp flush_buffer(%{buffer: buffer} = state) when map_size(buffer) == 0, do: state

  defp flush_buffer(%{buffer: buffer} = state) do
    entries = Map.values(buffer)

    try do
      Repo.insert_all(NodeExecution, entries,
        on_conflict: {:replace, @updatable_fields},
        conflict_target: [:id]
      )

      %{state | buffer: %{}}
    rescue
      e ->
        Logger.warning("Failed to flush node execution buffer",
          error: Exception.message(e),
          entries: length(entries)
        )

        state
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp current_time do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
