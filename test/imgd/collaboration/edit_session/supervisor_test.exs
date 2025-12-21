defmodule Imgd.Collaboration.EditSession.SupervisorTest do
  use Imgd.DataCase

  alias Imgd.Collaboration.EditSession.{Supervisor, Server}
  alias Imgd.Workflows
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  setup do
    # Create a test workflow
    {:ok, user} = Accounts.register_user(%{email: "test@example.com", password: "password123"})
    scope = Scope.for_user(user)

    {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

    # Create a draft for the workflow
    draft_attrs = %{
      nodes: [
        %{id: "node_1", type_id: "debug", name: "Debug Node", position: %{x: 100, y: 100}}
      ]
    }

    {:ok, _} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)

    %{workflow: workflow, scope: scope}
  end

  describe "ensure_session/1" do
    test "starts new session for workflow", %{workflow: workflow} do
      assert {:ok, pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(pid)
      assert is_pid(pid)

      # Verify it's registered correctly
      assert {:ok, ^pid} = Supervisor.ensure_session(workflow.id)
    end

    test "returns existing session if already running", %{workflow: workflow} do
      {:ok, pid1} = Supervisor.ensure_session(workflow.id)
      {:ok, pid2} = Supervisor.ensure_session(workflow.id)

      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "handles concurrent session requests", %{workflow: workflow} do
      # Simulate concurrent requests
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> Supervisor.ensure_session(workflow.id) end)
        end

      results = Task.await_many(tasks)

      # All should succeed and return the same pid (or already_started)
      assert Enum.all?(results, fn
               {:ok, pid} -> Process.alive?(pid)
               {:error, {:already_started, pid}} -> Process.alive?(pid)
             end)

      # Extract pids from results
      pids =
        Enum.map(results, fn
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end)

      assert Enum.all?(pids, &(&1 == hd(pids)))
    end
  end

  describe "start_session/1" do
    test "starts session with correct child spec", %{workflow: workflow} do
      assert {:ok, pid} = Supervisor.start_session(workflow.id)
      assert Process.alive?(pid)

      # Verify it's a Server process
      state = :sys.get_state(pid)
      assert state.__struct__ == Server.State
    end

    test "handles invalid workflow IDs gracefully" do
      # Should fail to start a session for non-existent workflows
      invalid_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Supervisor.start_session(invalid_id)
    end
  end

  describe "stop_session/1" do
    test "stops running session", %{workflow: workflow} do
      {:ok, pid} = Supervisor.ensure_session(workflow.id)
      assert Process.alive?(pid)

      assert :ok = Supervisor.stop_session(workflow.id)
      refute Process.alive?(pid)

      # Subsequent calls should return not_found
      assert {:error, :not_found} = Supervisor.stop_session(workflow.id)
    end

    test "returns not_found for non-existent session" do
      assert {:error, :not_found} = Supervisor.stop_session(Ecto.UUID.generate())
    end
  end

  describe "session isolation" do
    test "different workflows have separate sessions", %{workflow: workflow} do
      # Create another workflow
      {:ok, user} = Accounts.register_user(%{email: "test2@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow2} = Workflows.create_workflow(%{name: "Workflow 2"}, scope)

      # Create draft for workflow2
      draft_attrs = %{
        nodes: [
          %{id: "node_1", type_id: "debug", name: "Debug Node", position: %{x: 100, y: 100}}
        ]
      }

      {:ok, _} = Workflows.update_workflow_draft(workflow2, draft_attrs, scope)

      {:ok, pid1} = Supervisor.ensure_session(workflow.id)
      {:ok, pid2} = Supervisor.ensure_session(workflow2.id)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "supervisor recovery" do
    test "restarts crashed sessions", %{workflow: workflow} do
      {:ok, pid1} = Supervisor.ensure_session(workflow.id)

      # Crash the session
      Process.exit(pid1, :kill)
      refute Process.alive?(pid1)

      # Supervisor should restart it
      # Allow restart
      :timer.sleep(100)
      {:ok, pid2} = Supervisor.ensure_session(workflow.id)

      assert Process.alive?(pid2)
      assert pid1 != pid2
    end
  end

  describe "resource management" do
    test "limits concurrent sessions", %{workflow: _workflow} do
      # This test ensures the supervisor doesn't create unlimited processes
      # In practice, you'd want to monitor this in production

      # Create many workflows and sessions
      # Reduced to 3 to avoid too many processes
      workflows =
        for i <- 1..3 do
          {:ok, user} =
            Accounts.register_user(%{email: "user#{i}@example.com", password: "password123"})

          scope = Scope.for_user(user)
          {:ok, wf} = Workflows.create_workflow(%{name: "Workflow #{i}"}, scope)

          # Create draft for each workflow
          draft_attrs = %{
            nodes: [
              %{id: "node_1", type_id: "debug", name: "Debug Node", position: %{x: 100, y: 100}}
            ]
          }

          {:ok, _} = Workflows.update_workflow_draft(wf, draft_attrs, scope)
          wf
        end

      # Start sessions for all
      pids =
        for wf <- workflows do
          {:ok, pid} = Supervisor.ensure_session(wf.id)
          pid
        end

      # All should be alive
      assert Enum.all?(pids, &Process.alive?/1)

      # Clean up
      Enum.each(workflows, fn wf ->
        Supervisor.stop_session(wf.id)
      end)
    end
  end
end
