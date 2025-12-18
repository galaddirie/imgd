defmodule Imgd.Repo.Migrations.AllowNullWorkflowVersionOnExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      modify :workflow_version_id, :binary_id, null: true, from: :binary_id
    end
  end
end
