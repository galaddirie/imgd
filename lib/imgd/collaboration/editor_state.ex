defmodule Imgd.Collaboration.EditorState do
  @moduledoc """
  In-memory editor state for a collaborative session.

  Not persisted - reconstructed when session starts.
  """

  defstruct [
    :workflow_id,
    pinned_outputs: %{},      # %{node_id => output_data}
    disabled_nodes: MapSet.new(),
    disabled_mode: %{},       # %{node_id => :skip | :exclude}
    execution_start: nil,     # node_id for partial execution
    node_locks: %{},          # %{node_id => user_id} - soft locks
    lock_timestamps: %{}      # %{node_id => DateTime} - for timeout
  ]

  @lock_timeout_ms 30_000  # 30 seconds

  def pin_output(state, node_id, output_data) do
    %{state | pinned_outputs: Map.put(state.pinned_outputs, node_id, output_data)}
  end

  def unpin_output(state, node_id) do
    %{state | pinned_outputs: Map.delete(state.pinned_outputs, node_id)}
  end

  def disable_node(state, node_id, mode \\ :skip) do
    %{state |
      disabled_nodes: MapSet.put(state.disabled_nodes, node_id),
      disabled_mode: Map.put(state.disabled_mode, node_id, mode)
    }
  end

  def enable_node(state, node_id) do
    %{state |
      disabled_nodes: MapSet.delete(state.disabled_nodes, node_id),
      disabled_mode: Map.delete(state.disabled_mode, node_id)
    }
  end

  def acquire_lock(state, node_id, user_id) do
    now = DateTime.utc_now()

    case Map.get(state.node_locks, node_id) do
      nil ->
        {:ok, put_lock(state, node_id, user_id, now)}

      ^user_id ->
        # Already locked by same user - refresh
        {:ok, put_lock(state, node_id, user_id, now)}

      other_user_id ->
        # Check if lock has expired
        lock_time = Map.get(state.lock_timestamps, node_id)
        if DateTime.diff(now, lock_time, :millisecond) > @lock_timeout_ms do
          {:ok, put_lock(state, node_id, user_id, now)}
        else
          {:locked, other_user_id}
        end
    end
  end

  def release_lock(state, node_id, user_id) do
    case Map.get(state.node_locks, node_id) do
      ^user_id ->
        %{state |
          node_locks: Map.delete(state.node_locks, node_id),
          lock_timestamps: Map.delete(state.lock_timestamps, node_id)
        }
      _ ->
        state
    end
  end

  defp put_lock(state, node_id, user_id, timestamp) do
    %{state |
      node_locks: Map.put(state.node_locks, node_id, user_id),
      lock_timestamps: Map.put(state.lock_timestamps, node_id, timestamp)
    }
  end
end
