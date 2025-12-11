defmodule Imgd.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "draft"
      # Embedded schemas stored as JSONB
      add :nodes, :jsonb, null: false, default: "[]"
      add :connections, :jsonb, null: false, default: "[]"
      add :triggers, :jsonb, null: false, default: "[]"
      add :settings, :jsonb, null: false, default: "{}"
      add :current_version_tag, :string
      # published_version_id will be added after workflow_versions table exists
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:user_id])
    create index(:workflows, [:status])
    create index(:workflows, [:user_id, :status])
  end
end
