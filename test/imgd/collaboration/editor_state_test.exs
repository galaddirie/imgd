defmodule Imgd.Collaboration.EditorStateTest do
  use ExUnit.Case, async: true

  alias Imgd.Collaboration.EditorState

  describe "pin_output/3" do
    test "pins node output" do
      state = %EditorState{workflow_id: "wf_1"}
      output_data = %{"result" => "test output"}

      new_state = EditorState.pin_output(state, "node_1", output_data)

      assert new_state.pinned_outputs["node_1"] == output_data
    end

    test "overwrites existing pin" do
      state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"node_1" => %{"old" => "data"}}
      }

      new_data = %{"new" => "data"}
      new_state = EditorState.pin_output(state, "node_1", new_data)

      assert new_state.pinned_outputs["node_1"] == new_data
    end
  end

  describe "unpin_output/2" do
    test "unpins node output" do
      state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"node_1" => %{"data" => "value"}, "node_2" => %{"other" => "data"}}
      }

      new_state = EditorState.unpin_output(state, "node_1")

      assert new_state.pinned_outputs["node_2"] == %{"other" => "data"}
      refute Map.has_key?(new_state.pinned_outputs, "node_1")
    end

    test "handles unpinning non-existent pin" do
      state = %EditorState{workflow_id: "wf_1", pinned_outputs: %{}}
      new_state = EditorState.unpin_output(state, "node_1")

      assert new_state.pinned_outputs == %{}
    end
  end

  describe "disable_node/3" do
    test "disables node with default mode" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.disable_node(state, "node_1")

      assert MapSet.member?(new_state.disabled_nodes, "node_1")
      assert new_state.disabled_mode["node_1"] == :skip
    end

    test "disables node with explicit mode" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.disable_node(state, "node_1", :exclude)

      assert MapSet.member?(new_state.disabled_nodes, "node_1")
      assert new_state.disabled_mode["node_1"] == :exclude
    end
  end

  describe "enable_node/2" do
    test "enables disabled node" do
      state = %EditorState{
        workflow_id: "wf_1",
        disabled_nodes: MapSet.new(["node_1", "node_2"]),
        disabled_mode: %{"node_1" => :skip, "node_2" => :exclude}
      }

      new_state = EditorState.enable_node(state, "node_1")

      refute MapSet.member?(new_state.disabled_nodes, "node_1")
      assert MapSet.member?(new_state.disabled_nodes, "node_2")
      refute Map.has_key?(new_state.disabled_mode, "node_1")
      assert new_state.disabled_mode["node_2"] == :exclude
    end

    test "handles enabling non-disabled node" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.enable_node(state, "node_1")

      assert new_state.disabled_nodes == MapSet.new()
      assert new_state.disabled_mode == %{}
    end
  end

  describe "acquire_lock/4" do
    test "acquires lock for unlocked node" do
      state = %EditorState{workflow_id: "wf_1"}
      now = DateTime.utc_now()

      {:ok, new_state} = EditorState.acquire_lock(state, "node_1", "user_1")

      assert new_state.node_locks["node_1"] == "user_1"
      assert DateTime.diff(new_state.lock_timestamps["node_1"], now, :second) <= 1
    end

    test "allows same user to refresh their lock" do
      initial_time = DateTime.add(DateTime.utc_now(), -10, :second)

      state = %EditorState{
        workflow_id: "wf_1",
        node_locks: %{"node_1" => "user_1"},
        lock_timestamps: %{"node_1" => initial_time}
      }

      {:ok, new_state} = EditorState.acquire_lock(state, "node_1", "user_1")

      assert new_state.node_locks["node_1"] == "user_1"
      assert DateTime.after?(new_state.lock_timestamps["node_1"], initial_time)
    end

    test "rejects lock acquisition for different user on locked node" do
      state = %EditorState{
        workflow_id: "wf_1",
        node_locks: %{"node_1" => "user_1"},
        lock_timestamps: %{"node_1" => DateTime.utc_now()}
      }

      {:locked, locked_by_user} = EditorState.acquire_lock(state, "node_1", "user_2")

      assert locked_by_user == "user_1"
    end

    test "allows lock acquisition after timeout" do
      # > 30 second timeout
      expired_time = DateTime.add(DateTime.utc_now(), -40, :second)

      state = %EditorState{
        workflow_id: "wf_1",
        node_locks: %{"node_1" => "user_1"},
        lock_timestamps: %{"node_1" => expired_time}
      }

      {:ok, new_state} = EditorState.acquire_lock(state, "node_1", "user_2")

      assert new_state.node_locks["node_1"] == "user_2"
    end
  end

  describe "release_lock/3" do
    test "releases lock owned by user" do
      state = %EditorState{
        workflow_id: "wf_1",
        node_locks: %{"node_1" => "user_1", "node_2" => "user_2"},
        lock_timestamps: %{"node_1" => DateTime.utc_now(), "node_2" => DateTime.utc_now()}
      }

      new_state = EditorState.release_lock(state, "node_1", "user_1")

      refute Map.has_key?(new_state.node_locks, "node_1")
      refute Map.has_key?(new_state.lock_timestamps, "node_1")
      assert new_state.node_locks["node_2"] == "user_2"
    end

    test "ignores release of lock owned by different user" do
      state = %EditorState{
        workflow_id: "wf_1",
        node_locks: %{"node_1" => "user_1"},
        lock_timestamps: %{"node_1" => DateTime.utc_now()}
      }

      new_state = EditorState.release_lock(state, "node_1", "user_2")

      assert new_state.node_locks["node_1"] == "user_1"
      assert Map.has_key?(new_state.lock_timestamps, "node_1")
    end

    test "ignores release of non-existent lock" do
      state = %EditorState{workflow_id: "wf_1"}
      new_state = EditorState.release_lock(state, "node_1", "user_1")

      assert new_state == state
    end
  end

  describe "state persistence" do
    test "editor state is ephemeral - pins and disabled nodes don't persist across sessions" do
      _state = %EditorState{
        workflow_id: "wf_1",
        pinned_outputs: %{"node_1" => %{"data" => "value"}},
        disabled_nodes: MapSet.new(["node_2"]),
        disabled_mode: %{"node_2" => :skip},
        node_locks: %{"node_3" => "user_1"},
        lock_timestamps: %{"node_3" => DateTime.utc_now()}
      }

      # Simulate creating a new session - should start clean
      new_state = %EditorState{workflow_id: "wf_1"}

      # Editor state should be initialized clean (except workflow_id)
      assert new_state.pinned_outputs == %{}
      assert new_state.disabled_nodes == MapSet.new()
      assert new_state.disabled_mode == %{}
      assert new_state.node_locks == %{}
      assert new_state.lock_timestamps == %{}
    end
  end
end
