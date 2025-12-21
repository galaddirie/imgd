defmodule Imgd.Workflows.SharingTest do
  use Imgd.DataCase

  alias Imgd.Workflows.Sharing
  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts

  describe "workflow sharing" do
    setup do
      # Create two users
      {:ok, owner} =
        Accounts.register_user(%{email: "owner@example.com", password: "password123"})

      {:ok, viewer} =
        Accounts.register_user(%{email: "viewer@example.com", password: "password123"})

      {:ok, editor} =
        Accounts.register_user(%{email: "editor@example.com", password: "password123"})

      # Create a workflow owned by owner
      workflow_attrs = %{
        name: "Test Workflow",
        description: "A test workflow",
        user_id: owner.id
      }

      {:ok, workflow} = %Workflow{} |> Workflow.changeset(workflow_attrs) |> Repo.insert()

      %{owner: owner, viewer: viewer, editor: editor, workflow: workflow}
    end

    test "share_workflow/3 creates a share with viewer role", %{
      workflow: workflow,
      viewer: viewer
    } do
      assert {:ok, share} = Sharing.share_workflow(workflow, viewer, :viewer)
      assert share.role == :viewer
      assert share.workflow_id == workflow.id
      assert share.user_id == viewer.id
    end

    test "share_workflow/3 creates a share with editor role", %{
      workflow: workflow,
      editor: editor
    } do
      assert {:ok, share} = Sharing.share_workflow(workflow, editor, :editor)
      assert share.role == :editor
      assert share.workflow_id == workflow.id
      assert share.user_id == editor.id
    end

    test "share_workflow/3 fails when sharing with owner", %{workflow: workflow, owner: owner} do
      assert {:error, :cannot_share_with_owner} = Sharing.share_workflow(workflow, owner, :viewer)
    end

    test "can_view?/2 returns true for owner", %{workflow: workflow, owner: owner} do
      assert Sharing.can_view?(workflow, owner)
    end

    test "can_view?/2 returns true for shared viewer", %{workflow: workflow, viewer: viewer} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer, :viewer)
      assert Sharing.can_view?(workflow, viewer)
    end

    test "can_edit?/2 returns true for owner", %{workflow: workflow, owner: owner} do
      assert Sharing.can_edit?(workflow, owner)
    end

    test "can_edit?/2 returns true for shared editor", %{workflow: workflow, editor: editor} do
      {:ok, _share} = Sharing.share_workflow(workflow, editor, :editor)
      assert Sharing.can_edit?(workflow, editor)
    end

    test "can_edit?/2 returns false for shared viewer", %{workflow: workflow, viewer: viewer} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer, :viewer)
      refute Sharing.can_edit?(workflow, viewer)
    end

    test "can_view?/2 returns true for public workflow", %{workflow: workflow} do
      {:ok, public_workflow} = Sharing.make_public(workflow)
      assert Sharing.can_view?(public_workflow, nil)
    end

    test "can_edit?/2 returns false for public workflow without user", %{workflow: workflow} do
      {:ok, public_workflow} = Sharing.make_public(workflow)
      refute Sharing.can_edit?(public_workflow, nil)
    end

    test "make_public/1 makes workflow public", %{workflow: workflow} do
      refute workflow.public
      {:ok, updated_workflow} = Sharing.make_public(workflow)
      assert updated_workflow.public
    end

    test "make_private/1 makes workflow private", %{workflow: workflow} do
      {:ok, public_workflow} = Sharing.make_public(workflow)
      assert public_workflow.public
      {:ok, private_workflow} = Sharing.make_private(public_workflow)
      refute private_workflow.public
    end

    test "list_workflow_users/1 includes owner and shared users", %{
      workflow: workflow,
      owner: owner,
      viewer: viewer,
      editor: editor
    } do
      {:ok, _share1} = Sharing.share_workflow(workflow, viewer, :viewer)
      {:ok, _share2} = Sharing.share_workflow(workflow, editor, :editor)

      users = Sharing.list_workflow_users(workflow)

      # Should include owner, viewer, and editor
      assert length(users) == 3

      # Check that all users are present with correct roles
      user_roles = Map.new(users)
      assert user_roles[owner] == :owner
      assert user_roles[viewer] == :viewer
      assert user_roles[editor] == :editor
    end

    test "get_user_role/2 returns correct roles", %{
      workflow: workflow,
      owner: owner,
      viewer: viewer,
      editor: editor
    } do
      {:ok, _share1} = Sharing.share_workflow(workflow, viewer, :viewer)
      {:ok, _share2} = Sharing.share_workflow(workflow, editor, :editor)

      assert Sharing.get_user_role(workflow, owner) == :owner
      assert Sharing.get_user_role(workflow, viewer) == :viewer
      assert Sharing.get_user_role(workflow, editor) == :editor
    end

    test "unshare_workflow/2 removes share", %{workflow: workflow, viewer: viewer} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer, :viewer)
      assert Sharing.can_view?(workflow, viewer)

      {:ok, _deleted_share} = Sharing.unshare_workflow(workflow, viewer)
      refute Sharing.can_view?(workflow, viewer)
    end

    test "list_accessible_workflows/1 returns user's workflows", %{
      owner: owner,
      viewer: viewer,
      workflow: workflow
    } do
      # Owner should see their own workflow
      owner_workflows = Sharing.list_accessible_workflows(owner)
      assert length(owner_workflows) == 1
      assert hd(owner_workflows).id == workflow.id

      # Viewer should not see workflow before sharing
      viewer_workflows = Sharing.list_accessible_workflows(viewer)
      assert viewer_workflows == []

      # After sharing, viewer should see the workflow
      {:ok, _share} = Sharing.share_workflow(workflow, viewer, :viewer)
      viewer_workflows = Sharing.list_accessible_workflows(viewer)
      assert length(viewer_workflows) == 1
      assert hd(viewer_workflows).id == workflow.id
    end

    test "list_public_workflows/0 returns public workflows", %{workflow: workflow} do
      # Initially no public workflows
      assert Sharing.list_public_workflows() == []

      # After making public
      {:ok, _public_workflow} = Sharing.make_public(workflow)
      public_workflows = Sharing.list_public_workflows()
      assert length(public_workflows) == 1
      assert hd(public_workflows).id == workflow.id
    end
  end
end
