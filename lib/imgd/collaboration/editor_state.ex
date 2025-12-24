defmodule Imgd.Collaboration.EditorState do
  @moduledoc """
  In-memory editor state for a collaborative session.

  Not persisted - reconstructed when session starts.
  """

  defstruct [
    :workflow_id,
    # %{step_id => output_data}
    pinned_outputs: %{},
    disabled_steps: MapSet.new(),
    # %{step_id => :skip | :exclude}
    disabled_mode: %{},
    # step_id for partial execution
    execution_start: nil,
    # %{step_id => user_id} - soft locks
    step_locks: %{},
    # %{step_id => DateTime} - for timeout
    lock_timestamps: %{}
  ]

  # 30 seconds
  @lock_timeout_ms 30_000

  def pin_output(state, step_id, output_data) do
    %{state | pinned_outputs: Map.put(state.pinned_outputs, step_id, output_data)}
  end

  def unpin_output(state, step_id) do
    %{state | pinned_outputs: Map.delete(state.pinned_outputs, step_id)}
  end

  def disable_step(state, step_id, mode \\ :skip) do
    %{
      state
      | disabled_steps: MapSet.put(state.disabled_steps, step_id),
        disabled_mode: Map.put(state.disabled_mode, step_id, mode)
    }
  end

  def enable_step(state, step_id) do
    %{
      state
      | disabled_steps: MapSet.delete(state.disabled_steps, step_id),
        disabled_mode: Map.delete(state.disabled_mode, step_id)
    }
  end

  def acquire_lock(state, step_id, user_id) do
    now = DateTime.utc_now()

    case Map.get(state.step_locks, step_id) do
      nil ->
        {:ok, put_lock(state, step_id, user_id, now)}

      ^user_id ->
        # Already locked by same user - refresh
        {:ok, put_lock(state, step_id, user_id, now)}

      other_user_id ->
        # Check if lock has expired
        lock_time = Map.get(state.lock_timestamps, step_id)

        if DateTime.diff(now, lock_time, :millisecond) > @lock_timeout_ms do
          {:ok, put_lock(state, step_id, user_id, now)}
        else
          {:locked, other_user_id}
        end
    end
  end

  def release_lock(state, step_id, user_id) do
    case Map.get(state.step_locks, step_id) do
      ^user_id ->
        %{
          state
          | step_locks: Map.delete(state.step_locks, step_id),
            lock_timestamps: Map.delete(state.lock_timestamps, step_id)
        }

      _ ->
        state
    end
  end

  defp put_lock(state, step_id, user_id, timestamp) do
    %{
      state
      | step_locks: Map.put(state.step_locks, step_id, user_id),
        lock_timestamps: Map.put(state.lock_timestamps, step_id, timestamp)
    }
  end
end
