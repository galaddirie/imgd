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
      steps: [],
      connections: [],
      settings: %{}
    }
  end

  def workflow_version_factory do
    steps = [
      %{id: "step_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}}
    ]

    connections = []

    %Imgd.Workflows.WorkflowVersion{
      version_tag: sequence(:version_tag, &"1.0.#{&1}"),
      steps: steps,
      connections: connections,
      source_hash: "0000000000000000000000000000000000000000000000000000000000000000",
      workflow: insert(:workflow)
    }
  end

  def execution_factory do
    workflow = insert(:workflow)

    %Imgd.Executions.Execution{
      status: :pending,
      workflow: workflow,
      trigger: %Imgd.Executions.Execution.Trigger{type: :manual, data: %{}},
      context: %{}
    }
  end
end
