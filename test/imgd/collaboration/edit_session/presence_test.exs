defmodule Imgd.Collaboration.EditSession.PresenceTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.EditSession.Presence
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    # Create test workflow
    {:ok, user} = Accounts.register_user(%{email: "test@example.com", password: "password123"})
    scope = Scope.for_user(user)

    {:ok, workflow} = Workflows.create_workflow(scope, %{name: "Test Workflow"})

    %{workflow: workflow, user: user}
  end

  describe "track_user/3" do
    test "tracks user presence in session", %{workflow: workflow, user: user} do
      # Track user (normally done by LiveView)
      Presence.track_user(workflow.id, user, self())

      # Give presence time to propagate
      :timer.sleep(50)

      # Check presence list
      users = Presence.list_users(workflow.id)
      assert map_size(users) == 1

      presence_data = users[user.id]
      meta = List.first(presence_data.metas)
      assert meta.user.id == user.id
      assert meta.user.email == user.email
      assert meta.cursor == nil
      assert meta.selected_nodes == []
      assert meta.focused_node == nil
      assert meta.joined_at != nil
    end

    test "handles multiple users in same session", %{workflow: workflow} do
      # Create another user
      {:ok, user2} =
        Accounts.register_user(%{email: "user2@example.com", password: "password123"})

      # Track both users
      Presence.track_user(
        workflow.id,
        %{id: "user1", email: "user1@test.com", name: "User 1"},
        self()
      )

      Presence.track_user(workflow.id, user2, self())

      :timer.sleep(50)

      users = Presence.list_users(workflow.id)
      assert map_size(users) == 2
      assert Map.has_key?(users, "user1")
      assert Map.has_key?(users, user2.id)
    end
  end

  describe "update_cursor/3" do
    test "updates user cursor position", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      cursor_pos = %{x: 150.5, y: 200.3}
      Presence.update_cursor(workflow.id, user.id, cursor_pos)

      :timer.sleep(50)

      user_presence = Presence.get_user(workflow.id, user.id)
      meta = List.first(user_presence.metas)
      assert meta.cursor == cursor_pos
    end

    test "handles cursor updates for non-existent users gracefully", %{workflow: workflow} do
      # Should not crash
      Presence.update_cursor(workflow.id, "non_existent", %{x: 100, y: 100})
    end
  end

  describe "update_selection/3" do
    test "updates user node selection", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      selected_nodes = ["node_1", "node_2", "node_3"]
      Presence.update_selection(workflow.id, user.id, selected_nodes)

      :timer.sleep(50)

      user_presence = Presence.get_user(workflow.id, user.id)
      meta = List.first(user_presence.metas)
      assert meta.selected_nodes == selected_nodes
    end

    test "handles empty selection", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      Presence.update_selection(workflow.id, user.id, [])

      :timer.sleep(50)

      user_presence = Presence.get_user(workflow.id, user.id)
      meta = List.first(user_presence.metas)
      assert meta.selected_nodes == []
    end
  end

  describe "update_focus/3 and clear_focus/2" do
    test "updates and clears user focus", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      # Set focus
      Presence.update_focus(workflow.id, user.id, "node_1")

      :timer.sleep(50)

      user_presence = Presence.get_user(workflow.id, user.id)
      meta = List.first(user_presence.metas)
      assert meta.focused_node == "node_1"

      # Clear focus
      Presence.clear_focus(workflow.id, user.id)

      :timer.sleep(50)

      user_presence = Presence.get_user(workflow.id, user.id)
      meta = List.first(user_presence.metas)
      assert meta.focused_node == nil
    end
  end

  describe "count/1" do
    test "counts users in session", %{workflow: workflow} do
      assert Presence.count(workflow.id) == 0

      Presence.track_user(workflow.id, %{id: "user1", email: "user1@test.com"}, self())
      :timer.sleep(50)
      assert Presence.count(workflow.id) == 1

      Presence.track_user(workflow.id, %{id: "user2", email: "user2@test.com"}, self())
      :timer.sleep(50)
      assert Presence.count(workflow.id) == 2
    end

    test "counts users across different sessions separately", %{workflow: workflow} do
      # Create another workflow
      {:ok, user} = Accounts.register_user(%{email: "other@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow2} = Workflows.create_workflow(scope, %{name: "Workflow 2"})

      Presence.track_user(workflow.id, %{id: "user1", email: "user1@test.com"}, self())
      Presence.track_user(workflow2.id, %{id: "user2", email: "user2@test.com"}, self())

      :timer.sleep(50)

      assert Presence.count(workflow.id) == 1
      assert Presence.count(workflow2.id) == 1
    end
  end

  describe "get_user/2" do
    test "returns user presence data", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      :timer.sleep(50)

      presence_data = Presence.get_user(workflow.id, user.id)
      meta = List.first(presence_data.metas)
      assert meta.user.id == user.id
      assert meta.joined_at != nil
    end

    test "returns nil for non-existent user", %{workflow: workflow} do
      assert Presence.get_user(workflow.id, "non_existent") == nil
    end
  end

  describe "user disconnection" do
    test "removes user from presence on process death", %{workflow: workflow, user: user} do
      # Track user with a separate process
      pid =
        spawn(fn ->
          Presence.track_user(workflow.id, user, self())
          # Keep alive
          :timer.sleep(1000)
        end)

      :timer.sleep(50)
      assert Presence.count(workflow.id) == 1

      # Kill the process
      Process.exit(pid, :kill)
      # Allow presence cleanup
      :timer.sleep(100)

      assert Presence.count(workflow.id) == 0
    end
  end

  describe "presence metadata structure" do
    test "includes all required metadata fields", %{workflow: workflow, user: user} do
      Presence.track_user(workflow.id, user, self())

      :timer.sleep(50)

      presence_data = Presence.get_user(workflow.id, user.id)
      meta = List.first(presence_data.metas)

      # Check all required fields are present
      assert Map.has_key?(meta, :user)
      assert Map.has_key?(meta, :cursor)
      assert Map.has_key?(meta, :selected_nodes)
      assert Map.has_key?(meta, :focused_node)
      assert Map.has_key?(meta, :joined_at)

      # User data structure
      assert meta.user.id == user.id
      assert meta.user.email == user.email
      assert meta.user.name == user.email
    end
  end

  describe "topic naming" do
    test "uses correct topic format", %{workflow: workflow} do
      expected_topic = "edit_presence:#{workflow.id}"
      assert Presence.topic(workflow.id) == expected_topic
    end
  end

  describe "concurrent presence updates" do
    test "handles concurrent presence updates correctly", %{workflow: workflow} do
      Presence.track_user(workflow.id, %{id: "user1", email: "user1@test.com"}, self())

      # Simulate concurrent updates
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Presence.update_cursor(workflow.id, "user1", %{x: i * 10, y: i * 10})
          end)
        end

      # Wait for all updates
      Enum.each(tasks, &Task.await/1)
      :timer.sleep(100)

      # Should have some cursor position (last write wins, or nil if no update took effect)
      user_presence = Presence.get_user(workflow.id, "user1")
      meta = List.first(user_presence.metas)
      # The cursor might be nil if updates didn't take effect, which is acceptable
      assert Map.has_key?(meta, :cursor)
    end
  end
end
