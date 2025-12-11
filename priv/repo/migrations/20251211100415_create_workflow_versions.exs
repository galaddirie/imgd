defmodule Imgd.Repo.Migrations.CreateWorkflowVersions do
  use Ecto.Migration

  def change do
    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version_tag, :string, null: false
      add :source_hash, :string, size: 64, null: false
      # Embedded schemas stored as JSONB
      add :nodes, :jsonb, null: false, default: "[]"
      add :connections, :jsonb, null: false, default: "[]"
      add :triggers, :jsonb, null: false, default: "[]"
      add :changelog, :text
      add :published_at, :utc_datetime_usec
      add :published_by, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      # Immutable - only inserted_at, no updated_at
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workflow_versions, [:workflow_id])
    create unique_index(:workflow_versions, [:workflow_id, :version_tag])
    create index(:workflow_versions, [:source_hash])
  end
end
