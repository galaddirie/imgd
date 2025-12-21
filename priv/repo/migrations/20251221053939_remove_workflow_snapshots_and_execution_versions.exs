defmodule Imgd.Repo.Migrations.RemoveWorkflowSnapshotsAndExecutionVersions do
  use Ecto.Migration

  def change do
    drop_if_exists constraint(:executions, :executions_require_version_or_snapshot)
    drop_if_exists index(:executions, [:workflow_snapshot_id])
    drop_if_exists index(:executions, [:workflow_version_id])

    alter table(:executions) do
      remove :workflow_snapshot_id
      remove :workflow_version_id
    end

    drop_if_exists table(:workflow_snapshots)
  end
end
