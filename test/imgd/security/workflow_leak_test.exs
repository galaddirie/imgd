defmodule Imgd.Security.WorkflowLeakTest do
  use Imgd.DataCase
  import Imgd.Factory

  alias Imgd.Workflows
  alias Imgd.Accounts.Scope
  alias Imgd.Repo

  describe "workflow data isolation" do
    setup do
      owner = insert(:user)
      other_user = insert(:user)

      {:ok, workflow} =
        Workflows.create_workflow(%Scope{user: owner}, %{
          name: "Secret Workflow",
          nodes: [%{id: "n1", type_id: "secret", name: "Secret", config: %{}, position: %{}}],
          connections: [],
          triggers: []
        })

      # Ensure draft exists
      workflow = Repo.preload(workflow, :draft)

      {:ok, version} =
        Workflows.publish_workflow(%Scope{user: owner}, workflow, %{version_tag: "1.0.0"})

      %{owner: owner, other_user: other_user, workflow: workflow, version: version}
    end

    test "non-owner cannot load draft data through workflow metadata", %{
      workflow: workflow
    } do
      # Even if they have the ID, list_workflows won't show it if it's not theirs (current behavior)
      # But let's check what happens if we try to load it specifically if it were "public"

      # For now, let's verify that Jason serialization of Workflow doesn't include draft keys
      encoded = Jason.encode!(workflow)
      decoded = Jason.decode!(encoded)

      assert is_nil(decoded["nodes"])
      assert is_nil(decoded["connections"])
      assert is_nil(decoded["triggers"])
      assert is_nil(decoded["settings"])
    end

    test "non-owner cannot load draft data through workflow version association", %{
      version: version
    } do
      # Loading a public version
      loaded_version = Repo.preload(version, :workflow)

      # The associated workflow struct should NOT have draft data
      # (In our new model, Workflow schema doesn't even have these fields)
      refute Map.has_key?(loaded_version.workflow, :nodes)

      # And it should not have :draft preloaded
      assert %Ecto.Association.NotLoaded{} = loaded_version.workflow.draft
    end

    test "WorkflowDraft is not preloaded by default in Workflows.get_workflow", %{
      owner: owner,
      workflow: workflow
    } do
      # Even for owner, it's not preloaded unless requested
      wf = Workflows.get_workflow(%Scope{user: owner}, workflow.id)
      assert %Ecto.Association.NotLoaded{} = wf.draft
    end

    test "pinned outputs are linked to draft and kept private", %{
      owner: owner,
      other_user: other_user,
      workflow: workflow
    } do
      scope = %Scope{user: owner}
      Workflows.pin_node_output(scope, workflow, "n1", %{"data" => "secret_pin"})

      # Force sync to DB for testing
      {:ok, pid} = Workflows.EditingSessions.get_or_start_session(scope, workflow)
      Imgd.Workflows.EditingSession.Server.sync_persist(pid)

      # Owner can see pins
      pins = Workflows.EditingSessions.list_pins_for_workflow(scope, workflow)
      assert length(pins) == 1

      # Other user cannot see pins for this workflow
      other_scope = %Scope{user: other_user}
      other_pins = Workflows.EditingSessions.list_pins_for_workflow(other_scope, workflow)
      assert length(other_pins) == 0
    end
  end
end
