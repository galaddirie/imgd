defmodule Imgd.Repo.Migrations.RefactorDraftExecutionModelV2 do
  use Ecto.Migration

  def up do
    # 1. Create new tables
    create table(:workflow_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_user_id, references(:users, type: :binary_id), null: false
      add :source_hash, :string, size: 64, null: false
      add :nodes, :jsonb, null: false, default: "[]"
      add :connections, :jsonb, null: false, default: "[]"
      add :triggers, :jsonb, null: false, default: "[]"
      add :purpose, :string, size: 20, null: false, default: "preview"
      add :expires_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_snapshots, [:workflow_id, :source_hash],
             name: :workflow_snapshots_dedup_idx
           )

    create index(:workflow_snapshots, [:expires_at])

    create table(:editing_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :base_source_hash, :string, size: 64
      add :status, :string, size: 20, null: false, default: "active"
      add :last_activity_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :local_nodes, :jsonb
      add :local_connections, :jsonb
      timestamps()
    end

    create unique_index(:editing_sessions, [:workflow_id, :user_id],
             where: "status = 'active'",
             name: :editing_sessions_active_idx
           )

    create table(:pinned_outputs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :editing_session_id,
          references(:editing_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :node_id, :string, size: 255, null: false
      add :source_hash, :string, size: 64, null: false
      add :node_config_hash, :string, size: 32, null: false
      add :data, :jsonb, null: false
      add :source_execution_id, :binary_id
      add :label, :string, size: 255
      add :pinned_at, :utc_datetime_usec, null: false
      timestamps()
    end

    create unique_index(:pinned_outputs, [:editing_session_id, :node_id])
    create index(:pinned_outputs, [:user_id, :workflow_id])

    # Add size constraint for pin data (1MB)
    execute """
    ALTER TABLE pinned_outputs
    ADD CONSTRAINT pinned_outputs_data_size
    CHECK (pg_column_size(data) <= 1048576)
    """

    # 2. Modify executions table
    alter table(:executions) do
      add :workflow_snapshot_id, references(:workflow_snapshots, type: :binary_id)
      add :execution_type, :string, size: 20, null: false, default: "production"
      add :pinned_data, :jsonb, default: "{}"
    end

    # Remove legacy executions that don't have a version (violates new immutable source rule)
    execute "DELETE FROM executions WHERE workflow_version_id IS NULL"

    # Add check constraint for immutable source
    execute """
    ALTER TABLE executions
    ADD CONSTRAINT executions_immutable_source
    CHECK (
      (workflow_version_id IS NOT NULL AND workflow_snapshot_id IS NULL) OR
      (workflow_version_id IS NULL AND workflow_snapshot_id IS NOT NULL)
    )
    """

    # 3. Remove old pinned_outputs from workflows
    alter table(:workflows) do
      remove :pinned_outputs
    end
  end

  def down do
    alter table(:workflows) do
      add :pinned_outputs, :map, default: %{}
    end

    execute "ALTER TABLE executions DROP CONSTRAINT executions_immutable_source"

    alter table(:executions) do
      remove :workflow_snapshot_id
      remove :execution_type
      remove :pinned_data
    end

    drop table(:pinned_outputs)
    drop table(:editing_sessions)
    drop table(:workflow_snapshots)
  end
end
