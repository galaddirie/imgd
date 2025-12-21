defmodule Imgd.Repo.Migrations.CreateWorkflowsTables do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "draft"
      add :current_version_tag, :string
      add :published_version_id, :binary_id
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:user_id])
    create index(:workflows, [:status])
    create index(:workflows, [:published_version_id])

    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version_tag, :string, null: false
      add :source_hash, :string, null: false
      add :nodes, :map, null: false
      add :connections, :map
      add :triggers, :map
      add :changelog, :string
      add :published_at, :utc_datetime_usec
      add :published_by, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workflow_versions, [:workflow_id])
    create index(:workflow_versions, [:published_by])
    create unique_index(:workflow_versions, [:workflow_id, :version_tag])

    create table(:workflow_drafts, primary_key: false) do
      add :workflow_id,
          references(:workflows, on_delete: :delete_all, type: :binary_id),
          primary_key: true

      add :nodes, :map
      add :connections, :map
      add :triggers, :map
      add :settings, :map, null: false, default: %{timeout_ms: 300_000, max_retries: 3}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:workflow_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      add :created_by_user_id, references(:users, on_delete: :delete_all, type: :binary_id),
        null: false

      add :source_hash, :string, null: false
      add :nodes, :map
      add :connections, :map
      add :triggers, :map
      add :purpose, :string, null: false, default: "preview"
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workflow_snapshots, [:workflow_id])
    create index(:workflow_snapshots, [:created_by_user_id])
    create index(:workflow_snapshots, [:expires_at])

    create table(:editing_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :base_source_hash, :string
      add :status, :string, null: false, default: "active"
      add :last_activity_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :local_nodes, {:array, :map}
      add :local_connections, {:array, :map}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:editing_sessions, [:workflow_id, :user_id, :status])
    create index(:editing_sessions, [:expires_at])

    create table(:pinned_outputs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :editing_session_id,
          references(:editing_sessions, on_delete: :delete_all, type: :binary_id),
          null: false

      add :workflow_draft_id,
          references(:workflow_drafts,
            on_delete: :delete_all,
            type: :binary_id,
            column: :workflow_id
          ),
          null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :node_id, :string, null: false
      add :source_hash, :string, null: false
      add :node_config_hash, :string, null: false
      add :data, :map, null: false
      add :source_execution_id, :binary_id
      add :label, :string
      add :pinned_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pinned_outputs, [:editing_session_id, :node_id])
    create index(:pinned_outputs, [:workflow_draft_id])
    create index(:pinned_outputs, [:user_id])

    execute(
      """
      ALTER TABLE workflows
      ADD CONSTRAINT workflows_published_version_id_fkey
      FOREIGN KEY (published_version_id) REFERENCES workflow_versions(id)
      ON DELETE SET NULL
      """,
      """
      ALTER TABLE workflows
      DROP CONSTRAINT workflows_published_version_id_fkey
      """
    )
  end
end
