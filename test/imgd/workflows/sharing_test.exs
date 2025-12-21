defmodule Imgd.Workflows.SharingTest do
  use Imgd.DataCase

  alias Imgd.Workflows.Sharing
  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  describe "workflow sharing" do
    setup do
      # Create two users
      {:ok, owner} =
        Accounts.register_user(%{email: "owner@example.com", password: "password123"})

      {:ok, viewer} =
        Accounts.register_user(%{email: "viewer@example.com", password: "password123"})

      {:ok, editor} =
        Accounts.register_user(%{email: "editor@example.com", password: "password123"})

      # Create scopes for users
      owner_scope = Scope.for_user(owner)
      viewer_scope = Scope.for_user(viewer)
      editor_scope = Scope.for_user(editor)

      # Create a workflow owned by owner
      workflow_attrs = %{
        name: "Test Workflow",
        description: "A test workflow",
        user_id: owner.id
      }

      {:ok, workflow} = %Workflow{} |> Workflow.changeset(workflow_attrs) |> Repo.insert()

      %{owner: owner, viewer: viewer, editor: editor, owner_scope: owner_scope, viewer_scope: viewer_scope, editor_scope: editor_scope, workflow: workflow}
    end

    test "share_workflow/3 creates a share with viewer role", %{
      workflow: workflow,
      viewer_scope: viewer_scope
    } do
      assert {:ok, share} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      assert share.role == :viewer
      assert share.workflow_id == workflow.id
      assert share.user_id == viewer_scope.user.id
    end

    test "share_workflow/3 creates a share with editor role", %{
      workflow: workflow,
      editor_scope: editor_scope
    } do
      assert {:ok, share} = Sharing.share_workflow(workflow, editor_scope, :editor)
      assert share.role == :editor
      assert share.workflow_id == workflow.id
      assert share.user_id == editor_scope.user.id
    end

    test "share_workflow/3 fails when sharing with owner", %{workflow: workflow, owner_scope: owner_scope} do
      assert {:error, :cannot_share_with_owner} = Sharing.share_workflow(workflow, owner_scope, :viewer)
    end

    test "can_view?/2 returns true for owner", %{workflow: workflow, owner_scope: owner_scope} do
      assert Sharing.can_view?(workflow, owner_scope)
    end

    test "can_view?/2 returns true for shared viewer", %{workflow: workflow, viewer_scope: viewer_scope} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      assert Sharing.can_view?(workflow, viewer_scope)
    end

    test "can_edit?/2 returns true for owner", %{workflow: workflow, owner_scope: owner_scope} do
      assert Sharing.can_edit?(workflow, owner_scope)
    end

    test "can_edit?/2 returns true for shared editor", %{workflow: workflow, editor_scope: editor_scope} do
      {:ok, _share} = Sharing.share_workflow(workflow, editor_scope, :editor)
      assert Sharing.can_edit?(workflow, editor_scope)
    end

    test "can_edit?/2 returns false for shared viewer", %{workflow: workflow, viewer_scope: viewer_scope} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      refute Sharing.can_edit?(workflow, viewer_scope)
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
      viewer_scope: viewer_scope,
      editor_scope: editor_scope
    } do
      {:ok, _share1} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      {:ok, _share2} = Sharing.share_workflow(workflow, editor_scope, :editor)

      users = Sharing.list_workflow_users(workflow)

      # Should include owner, viewer, and editor
      assert length(users) == 3

      # Check that all users are present with correct roles
      user_roles = Map.new(users)
      assert user_roles[owner] == :owner
      assert user_roles[viewer_scope.user] == :viewer
      assert user_roles[editor_scope.user] == :editor
    end

    test "get_user_role/2 returns correct roles", %{
      workflow: workflow,
      owner_scope: owner_scope,
      viewer_scope: viewer_scope,
      editor_scope: editor_scope
    } do
      {:ok, _share1} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      {:ok, _share2} = Sharing.share_workflow(workflow, editor_scope, :editor)

      assert Sharing.get_user_role(workflow, owner_scope) == :owner
      assert Sharing.get_user_role(workflow, viewer_scope) == :viewer
      assert Sharing.get_user_role(workflow, editor_scope) == :editor
    end

    test "unshare_workflow/2 removes share", %{workflow: workflow, viewer_scope: viewer_scope} do
      {:ok, _share} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      assert Sharing.can_view?(workflow, viewer_scope)

      {:ok, _deleted_share} = Sharing.unshare_workflow(workflow, viewer_scope)
      refute Sharing.can_view?(workflow, viewer_scope)
    end

    test "list_accessible_workflows/1 returns user's workflows", %{
      owner_scope: owner_scope,
      viewer_scope: viewer_scope,
      workflow: workflow
    } do
      # Owner should see their own workflow
      owner_workflows = Sharing.list_accessible_workflows(owner_scope)
      assert length(owner_workflows) == 1
      assert hd(owner_workflows).id == workflow.id

      # Viewer should not see workflow before sharing
      viewer_workflows = Sharing.list_accessible_workflows(viewer_scope)
      assert viewer_workflows == []

      # After sharing, viewer should see the workflow
      {:ok, _share} = Sharing.share_workflow(workflow, viewer_scope, :viewer)
      viewer_workflows = Sharing.list_accessible_workflows(viewer_scope)
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
