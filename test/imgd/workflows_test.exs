defmodule Imgd.WorkflowsTest do
  use Imgd.DataCase, async: true

  alias Imgd.Workflows
  alias Imgd.Workflows.{Workflow, WorkflowVersion, WorkflowDraft, WorkflowShare}
  alias Imgd.Executions.Execution
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope
  alias Imgd.Repo

  describe "workflow CRUD operations" do
    setup do
      # Create test users
      {:ok, user1} =
        Accounts.register_user(%{email: "user1@example.com", password: "password123"})

      {:ok, user2} =
        Accounts.register_user(%{email: "user2@example.com", password: "password123"})

      {:ok, user3} =
        Accounts.register_user(%{email: "user3@example.com", password: "password123"})

      # Create scopes
      scope1 = Scope.for_user(user1)
      scope2 = Scope.for_user(user2)
      scope3 = Scope.for_user(user3)

      %{user1: user1, user2: user2, user3: user3, scope1: scope1, scope2: scope2, scope3: scope3}
    end

    test "create_workflow/2 creates a new workflow", %{scope1: scope1} do
      attrs = %{
        name: "Test Workflow",
        description: "A test workflow description"
      }

      assert {:ok, workflow} = Workflows.create_workflow(attrs, scope1)
      assert workflow.name == "Test Workflow"
      assert workflow.description == "A test workflow description"
      assert workflow.user_id == scope1.user.id
      assert workflow.status == :draft
      refute workflow.public
    end

    test "create_workflow/2 validates required fields", %{scope1: scope1} do
      # Missing name
      attrs = %{description: "Description without name"}
      assert {:error, changeset} = Workflows.create_workflow(attrs, scope1)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "get_workflow/2 returns workflow for owner", %{scope1: scope1} do
      # Create workflow
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      # Owner can access
      assert {:ok, fetched} = Workflows.get_workflow(workflow.id, scope1)
      assert fetched.id == workflow.id
    end

    test "get_workflow/2 returns error for non-existent workflow", %{scope1: scope1} do
      assert {:error, :not_found} = Workflows.get_workflow(Ecto.UUID.generate(), scope1)
    end

    test "get_workflow/2 returns error when user lacks access", %{scope1: scope1, scope2: scope2} do
      # Create workflow for user1
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      # User2 cannot access
      assert {:error, :not_found} = Workflows.get_workflow(workflow.id, scope2)
    end

    test "get_workflow/2 allows access to public workflows", %{scope1: scope1, scope2: scope2} do
      # Create and make workflow public
      {:ok, workflow} = Workflows.create_workflow(%{name: "Public Workflow"}, scope1)
      {:ok, public_workflow} = Imgd.Workflows.Sharing.make_public(workflow)

      # Any user can access public workflows
      assert {:ok, fetched} = Workflows.get_workflow(public_workflow.id, scope2)
      assert fetched.id == public_workflow.id
    end

    test "update_workflow/3 updates workflow for owner", %{scope1: scope1} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Original Name"}, scope1)

      update_attrs = %{
        name: "Updated Name",
        description: "Updated description",
        public: true
      }

      assert {:ok, updated} = Workflows.update_workflow(workflow, update_attrs, scope1)
      assert updated.name == "Updated Name"
      assert updated.description == "Updated description"
      assert updated.public
    end

    test "update_workflow/3 returns error when user lacks edit permission", %{
      scope1: scope1,
      scope2: scope2
    } do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      assert {:error, :access_denied} =
               Workflows.update_workflow(workflow, %{name: "New Name"}, scope2)
    end

    test "delete_workflow/2 deletes workflow for owner", %{scope1: scope1} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      assert {:ok, deleted} = Workflows.delete_workflow(workflow, scope1)
      assert deleted.id == workflow.id

      # Verify it's gone
      assert {:error, :not_found} = Workflows.get_workflow(workflow.id, scope1)
    end

    test "delete_workflow/2 returns error when user is not owner", %{
      scope1: scope1,
      scope2: scope2
    } do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      assert {:error, :access_denied} = Workflows.delete_workflow(workflow, scope2)
    end

    test "archive_workflow/2 archives workflow for owner", %{scope1: scope1} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)
      assert workflow.status == :draft

      assert {:ok, archived} = Workflows.archive_workflow(workflow, scope1)
      assert archived.status == :archived
    end

    test "archive_workflow/2 returns error when user lacks permission", %{
      scope1: scope1,
      scope2: scope2
    } do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope1)

      assert {:error, :access_denied} = Workflows.archive_workflow(workflow, scope2)
    end
  end

  describe "workflow listing" do
    setup do
      {:ok, user1} =
        Accounts.register_user(%{email: "user1@example.com", password: "password123"})

      {:ok, user2} =
        Accounts.register_user(%{email: "user2@example.com", password: "password123"})

      scope1 = Scope.for_user(user1)
      scope2 = Scope.for_user(user2)

      # Create workflows
      {:ok, workflow1} = Workflows.create_workflow(%{name: "Workflow 1"}, scope1)
      {:ok, workflow2} = Workflows.create_workflow(%{name: "Workflow 2"}, scope1)
      {:ok, workflow3} = Workflows.create_workflow(%{name: "Workflow 3"}, scope2)

      %{
        scope1: scope1,
        scope2: scope2,
        workflow1: workflow1,
        workflow2: workflow2,
        workflow3: workflow3
      }
    end

    test "list_workflows/1 returns user's own workflows", %{scope1: scope1} do
      workflows = Workflows.list_workflows(scope1)
      assert length(workflows) == 2
      workflow_names = Enum.map(workflows, & &1.name) |> Enum.sort()
      assert workflow_names == ["Workflow 1", "Workflow 2"]
    end

    test "list_workflows/1 returns empty list for nil scope" do
      assert Workflows.list_workflows(nil) == []
    end

    test "list_workflows/1 includes shared workflows", %{
      scope1: scope1,
      scope2: _scope2,
      workflow3: workflow3
    } do
      # Share workflow3 with user1
      {:ok, _share} = Imgd.Workflows.Sharing.share_workflow(workflow3, scope1, :viewer)

      workflows = Workflows.list_workflows(scope1)
      assert length(workflows) == 3
      workflow_names = Enum.map(workflows, & &1.name) |> Enum.sort()
      assert "Workflow 3" in workflow_names
    end

    test "list_workflows/1 includes public workflows", %{
      scope1: scope1,
      scope2: _scope2,
      workflow3: workflow3
    } do
      # Make workflow3 public
      {:ok, _public_workflow} = Imgd.Workflows.Sharing.make_public(workflow3)

      workflows = Workflows.list_workflows(scope1)
      assert length(workflows) == 3
      workflow_names = Enum.map(workflows, & &1.name) |> Enum.sort()
      assert "Workflow 3" in workflow_names
    end

    test "list_owned_workflows/1 returns only owned workflows", %{
      scope1: scope1,
      scope2: _scope2,
      workflow3: workflow3
    } do
      # Share workflow3 with user1
      {:ok, _share} = Imgd.Workflows.Sharing.share_workflow(workflow3, scope1, :viewer)

      owned_workflows = Workflows.list_owned_workflows(scope1)
      assert length(owned_workflows) == 2
      workflow_names = Enum.map(owned_workflows, & &1.name) |> Enum.sort()
      assert workflow_names == ["Workflow 1", "Workflow 2"]
    end

    test "list_public_workflows/0 returns only public workflows", %{workflow3: workflow3} do
      # Initially no public workflows
      assert Workflows.Sharing.list_public_workflows() == []

      # Make one public
      {:ok, _public_workflow} = Imgd.Workflows.Sharing.make_public(workflow3)
      public_workflows = Workflows.Sharing.list_public_workflows()
      assert length(public_workflows) == 1
      assert hd(public_workflows).id == workflow3.id
    end
  end

  describe "workflow versions and publishing" do
    setup do
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)

      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

      # Create a draft for the workflow
      draft_attrs = %{
        nodes: [%{id: "node1", type_id: "input", name: "Input Node", config: %{}}],
        connections: [],
        triggers: [%{type: :manual, config: %{}}],
        settings: %{timeout_ms: 300_000, max_retries: 3}
      }

      {:ok, _draft} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)

      %{scope: scope, workflow: workflow}
    end

    test "publish_workflow/3 creates a published version", %{scope: scope, workflow: workflow} do
      version_attrs = %{
        version_tag: "1.0.0",
        changelog: "Initial release"
      }

      assert {:ok, {updated_workflow, version}} =
               Workflows.publish_workflow(workflow, version_attrs, scope)

      assert updated_workflow.status == :active
      assert updated_workflow.current_version_tag == "1.0.0"
      assert updated_workflow.published_version_id == version.id

      assert version.version_tag == "1.0.0"
      assert version.changelog == "Initial release"
      assert version.workflow_id == workflow.id
      assert version.published_by == scope.user.id
    end

    test "publish_workflow/3 fails when user lacks edit permission", %{workflow: workflow} do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      version_attrs = %{version_tag: "1.0.0"}

      assert {:error, :access_denied} =
               Workflows.publish_workflow(workflow, version_attrs, other_scope)
    end

    test "get_workflow_version/2 returns version for user with access", %{
      scope: scope,
      workflow: workflow
    } do
      # First publish a version
      {:ok, {_workflow, version}} =
        Workflows.publish_workflow(workflow, %{version_tag: "1.0.0"}, scope)

      assert {:ok, fetched} = Workflows.get_workflow_version(version.id, scope)
      assert fetched.id == version.id
    end

    test "get_workflow_version/2 returns error for non-existent version", %{scope: scope} do
      assert {:error, :not_found} = Workflows.get_workflow_version(Ecto.UUID.generate(), scope)
    end

    test "list_workflow_versions/2 returns versions for accessible workflow", %{
      scope: scope,
      workflow: workflow
    } do
      # Publish multiple versions
      {:ok, {_w1, _v1}} = Workflows.publish_workflow(workflow, %{version_tag: "1.0.0"}, scope)
      {:ok, {_w2, _v2}} = Workflows.publish_workflow(workflow, %{version_tag: "1.1.0"}, scope)

      versions = Workflows.list_workflow_versions(workflow, scope)
      assert length(versions) == 2
      version_tags = Enum.map(versions, & &1.version_tag) |> Enum.sort()
      assert version_tags == ["1.0.0", "1.1.0"]
    end

    test "list_workflow_versions/2 returns empty list when user lacks access", %{
      scope: scope,
      workflow: workflow
    } do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      # Publish a version
      {:ok, {_workflow, _version}} =
        Workflows.publish_workflow(workflow, %{version_tag: "1.0.0"}, scope)

      # Other user cannot see versions
      assert Workflows.list_workflow_versions(workflow, other_scope) == []
    end
  end

  describe "workflow drafts" do
    setup do
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

      %{scope: scope, workflow: workflow}
    end

    test "update_workflow_draft/3 creates draft for new workflow", %{
      scope: scope,
      workflow: workflow
    } do
      draft_attrs = %{
        nodes: [%{id: "node1", type_id: "input", name: "Input Node", config: %{}}],
        connections: [],
        triggers: [%{type: :manual, config: %{}}],
        settings: %{timeout_ms: 300_000, max_retries: 3}
      }

      assert {:ok, draft} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)
      assert draft.workflow_id == workflow.id
      assert length(draft.nodes) == 1
      assert hd(draft.nodes).id == "node1"
      assert hd(draft.nodes).type_id == "input"
      assert hd(draft.nodes).name == "Input Node"
      assert length(draft.connections) == 0
      assert length(draft.triggers) == 1
    end

    test "update_workflow_draft/3 updates existing draft", %{scope: scope, workflow: workflow} do
      # Create initial draft
      initial_attrs = %{
        nodes: [%{id: "node1", type_id: "input", name: "Input Node", config: %{}}],
        connections: [],
        triggers: []
      }

      {:ok, draft} = Workflows.update_workflow_draft(workflow, initial_attrs, scope)

      # Update draft
      update_attrs = %{
        nodes: [
          %{id: "node1", type_id: "input", name: "Input Node", config: %{}},
          %{id: "node2", type_id: "output", name: "Output Node", config: %{}}
        ]
      }

      {:ok, updated_draft} = Workflows.update_workflow_draft(workflow, update_attrs, scope)

      assert updated_draft.workflow_id == draft.workflow_id
      assert length(updated_draft.nodes) == 2
      node_ids = Enum.map(updated_draft.nodes, & &1.id) |> Enum.sort()
      assert node_ids == ["node1", "node2"]
    end

    test "update_workflow_draft/3 fails when user lacks edit permission", %{workflow: workflow} do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      draft_attrs = %{nodes: %{}, connections: [], triggers: []}

      assert {:error, :access_denied} =
               Workflows.update_workflow_draft(workflow, draft_attrs, other_scope)
    end
  end

  describe "workflow executions" do
    setup do
      {:ok, user} = Accounts.register_user(%{email: "user@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test Workflow"}, scope)

      # Create and publish a version
      draft_attrs = %{
        nodes: [%{id: "node1", type_id: "input", name: "Input Node", config: %{}}],
        connections: [],
        triggers: [%{type: :manual, config: %{}}]
      }

      {:ok, _draft} = Workflows.update_workflow_draft(workflow, draft_attrs, scope)

      {:ok, {_workflow, version}} =
        Workflows.publish_workflow(workflow, %{version_tag: "1.0.0"}, scope)

      # Create some executions
      {:ok, execution1} = create_execution_for_workflow(workflow, version, :pending)
      {:ok, execution2} = create_execution_for_workflow(workflow, version, :running)
      {:ok, execution3} = create_execution_for_workflow(workflow, version, :failed)

      %{scope: scope, workflow: workflow, executions: [execution1, execution2, execution3]}
    end

    test "list_workflow_executions/2 returns executions for accessible workflow", %{
      scope: scope,
      workflow: workflow,
      executions: executions
    } do
      fetched_executions = Workflows.list_workflow_executions(workflow, scope)
      assert length(fetched_executions) == 3

      execution_ids = Enum.map(fetched_executions, & &1.id) |> MapSet.new()
      expected_ids = Enum.map(executions, & &1.id) |> MapSet.new()
      assert MapSet.equal?(execution_ids, expected_ids)
    end

    test "list_workflow_executions/2 returns empty list when user lacks access", %{
      workflow: workflow
    } do
      {:ok, other_user} =
        Accounts.register_user(%{email: "other@example.com", password: "password123"})

      other_scope = Scope.for_user(other_user)

      assert Workflows.list_workflow_executions(workflow, other_scope) == []
    end

    test "count_workflow_executions/1 returns execution counts by status", %{workflow: workflow} do
      counts = Workflows.count_workflow_executions(workflow)
      assert counts[:pending] == 1
      assert counts[:running] == 1
      assert counts[:failed] == 1
    end

    test "count_workflow_executions/1 returns empty map for workflow with no executions" do
      {:ok, user} = Accounts.register_user(%{email: "new@example.com", password: "password123"})
      scope = Scope.for_user(user)
      {:ok, empty_workflow} = Workflows.create_workflow(%{name: "Empty Workflow"}, scope)

      assert Workflows.count_workflow_executions(empty_workflow) == %{}
    end
  end

  # Helper function to create test executions
  defp create_execution_for_workflow(workflow, version, status) do
    execution_attrs = %{
      workflow_id: workflow.id,
      workflow_version_id: version.id,
      trigger: %{type: :manual, config: %{}},
      execution_type: :production,
      status: status
    }

    %Execution{}
    |> Execution.changeset(execution_attrs)
    |> Repo.insert()
  end
end
