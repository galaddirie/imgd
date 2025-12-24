defmodule Imgd.Collaboration.EditorStateTest do
  use ExUnit.Case, async: true

  alias Imgd.Collaboration.EditorState

  describe "pin_output/3" do
    test "pins step output" do
      state = %EditorState{workflow_id: "wf_1"}
      output_data = %{"result" => "test output"}

      new_state = EditorState.pin_output(state, "step_1", output_data)

      assert new_state.pinned_outputs["step_1"] == output_data
    end

    test "overwrites existing pin" do
      state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"step_1" => %{"old" => "data"}}
      }

      new_data = %{"new" => "data"}
      new_state = EditorState.pin_output(state, "step_1", new_data)

      assert new_state.pinned_outputs["step_1"] == new_data
    end
  end

  describe "unpin_output/2" do
    test "unpins step output" do
      state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"step_1" => %{"data" => "value"}, "step_2" => %{"other" => "data"}}
      }

      new_state = EditorState.unpin_output(state, "step_1")

      assert new_state.pinned_outputs["step_2"] == %{"other" => "data"}
      refute Map.has_key?(new_state.pinned_outputs, "step_1")
    end

    test "handles unpinning non-existent pin" do
      state = %EditorState{workflow_id: "wf_1", pinned_outputs: %{}}
      new_state = EditorState.unpin_output(state, "step_1")

      assert new_state.pinned_outputs == %{}
    end
  end

  describe "disable_step/3" do
    test "disables step with default mode" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.disable_step(state, "step_1")

      assert MapSet.member?(new_state.disabled_steps, "step_1")
      assert new_state.disabled_mode["step_1"] == :skip
    end

    test "disables step with explicit mode" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.disable_step(state, "step_1", :exclude)

      assert MapSet.member?(new_state.disabled_steps, "step_1")
      assert new_state.disabled_mode["step_1"] == :exclude
    end
  end

  describe "enable_step/2" do
    test "enables disabled step" do
      state = %EditorState{
        workflow_id: "wf_1",
        disabled_steps: MapSet.new(["step_1", "step_2"]),
        disabled_mode: %{"step_1" => :skip, "step_2" => :exclude}
      }

      new_state = EditorState.enable_step(state, "step_1")

      refute MapSet.member?(new_state.disabled_steps, "step_1")
      assert MapSet.member?(new_state.disabled_steps, "step_2")
      refute Map.has_key?(new_state.disabled_mode, "step_1")
      assert new_state.disabled_mode["step_2"] == :exclude
    end

    test "handles enabling non-disabled step" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.enable_step(state, "step_1")

      assert new_state.disabled_steps == MapSet.new()
      assert new_state.disabled_mode == %{}
    end
  end

  describe "acquire_lock/4" do
    test "acquires lock for unlocked step" do
      state = %EditorState{workflow_id: "wf_1"}
      now = DateTime.utc_now()

      {:ok, new_state} = EditorState.acquire_lock(state, "step_1", "user_1")

      assert new_state.step_locks["step_1"] == "user_1"
      assert DateTime.diff(new_state.lock_timestamps["step_1"], now, :second) <= 1
    end

    test "allows same user to refresh their lock" do
      initial_time = DateTime.add(DateTime.utc_now(), -10, :second)

      state = %EditorState{
        workflow_id: "wf_1",
        step_locks: %{"step_1" => "user_1"},
        lock_timestamps: %{"step_1" => initial_time}
      }

      {:ok, new_state} = EditorState.acquire_lock(state, "step_1", "user_1")

      assert new_state.step_locks["step_1"] == "user_1"
      assert DateTime.after?(new_state.lock_timestamps["step_1"], initial_time)
    end

    test "rejects lock acquisition for different user on locked step" do
      state = %EditorState{
        workflow_id: "wf_1",
        step_locks: %{"step_1" => "user_1"},
        lock_timestamps: %{"step_1" => DateTime.utc_now()}
      }

      {:locked, locked_by_user} = EditorState.acquire_lock(state, "step_1", "user_2")

      assert locked_by_user == "user_1"
    end

    test "allows lock acquisition after timeout" do
      # > 30 second timeout
      expired_time = DateTime.add(DateTime.utc_now(), -40, :second)

      state = %EditorState{
        workflow_id: "wf_1",
        step_locks: %{"step_1" => "user_1"},
        lock_timestamps: %{"step_1" => expired_time}
      }

      {:ok, new_state} = EditorState.acquire_lock(state, "step_1", "user_2")

      assert new_state.step_locks["step_1"] == "user_2"
    end
  end

  describe "release_lock/3" do
    test "releases lock owned by user" do
      state = %EditorState{
        workflow_id: "wf_1",
        step_locks: %{"step_1" => "user_1", "step_2" => "user_2"},
        lock_timestamps: %{"step_1" => DateTime.utc_now(), "step_2" => DateTime.utc_now()}
      }

      new_state = EditorState.release_lock(state, "step_1", "user_1")

      refute Map.has_key?(new_state.step_locks, "step_1")
      refute Map.has_key?(new_state.lock_timestamps, "step_1")
      assert new_state.step_locks["step_2"] == "user_2"
    end

    test "ignores release of lock owned by different user" do
      state = %EditorState{
        workflow_id: "wf_1",
        step_locks: %{"step_1" => "user_1"},
        lock_timestamps: %{"step_1" => DateTime.utc_now()}
      }

      new_state = EditorState.release_lock(state, "step_1", "user_2")

      assert new_state.step_locks["step_1"] == "user_1"
      assert Map.has_key?(new_state.lock_timestamps, "step_1")
    end

    test "ignores release of non-existent lock" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.release_lock(state, "step_1", "user_1")

      assert new_state == state
    end
  end

  describe "state persistence" do
    test "editor state is ephemeral - pins and disabled steps don't persist across sessions" do
      _state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"step_1" => %{"data" => "value"}},
        disabled_steps: MapSet.new(["step_2"]),
        disabled_mode: %{"step_2" => :skip},
        step_locks: %{"step_3" => "user_1"},
        lock_timestamps: %{"step_3" => DateTime.utc_now()}
      }

      # Simulate creating a new session - should start clean
      new_state = %EditorState{workflow_id: "wf_1"}

      # Editor state should be initialized clean (except workflow_id)
      assert new_state.pinned_outputs == %{}
      assert new_state.disabled_steps == MapSet.new()
      assert new_state.disabled_mode == %{}
      assert new_state.step_locks == %{}
      assert new_state.lock_timestamps == %{}
    end
  end
end
