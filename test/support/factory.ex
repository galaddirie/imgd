defmodule Imgd.Factory do
  use ExMachina.Ecto, repo: Imgd.Repo

  def user_factory do
    %Imgd.Accounts.User{
      email: sequence(:email, &"user#{&1}@example.com"),
      hashed_password: Pbkdf2.hash_pwd_salt("hello world!"),
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  def workflow_factory do
    %Imgd.Workflows.Workflow{
      name: sequence(:name, &"Workflow #{&1}"),
      status: :active,
      user: insert(:user)
    }
  end

  def workflow_draft_factory do
    %Imgd.Workflows.WorkflowDraft{
      workflow_id: sequence(:workflow_id, &"#{&1}"),
      nodes: [],
      connections: [],
      triggers: [],
      settings: %{}
    }
  end

  def workflow_version_factory do
    nodes = [
      %{id: "node_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}}
    ]

    connections = []
    triggers = []

    %Imgd.Workflows.WorkflowVersion{
      version_tag: sequence(:version_tag, &"1.0.#{&1}"),
      nodes: nodes,
      connections: connections,
      triggers: triggers,
      source_hash:
        Imgd.Workflows.WorkflowVersion.compute_source_hash(nodes, connections, triggers),
      workflow: insert(:workflow)
    }
  end

  def workflow_snapshot_factory do
    nodes = [
      %{id: "node_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}}
    ]

    connections = []
    triggers = []

    %Imgd.Workflows.WorkflowSnapshot{
      workflow: insert(:workflow),
      created_by: insert(:user),
      nodes: nodes,
      connections: connections,
      triggers: triggers,
      source_hash:
        Imgd.Workflows.WorkflowSnapshot.compute_source_hash(nodes, connections, triggers),
      purpose: :preview
    }
  end

  def execution_factory do
    workflow = insert(:workflow)

    %Imgd.Executions.Execution{
      status: :pending,
      workflow: workflow,
      workflow_version: insert(:workflow_version, workflow: workflow),
      trigger: %{type: :manual, data: %{}},
      context: %{}
    }
  end
end
