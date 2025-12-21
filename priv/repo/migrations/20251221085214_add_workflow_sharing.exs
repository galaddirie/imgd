defmodule Imgd.Repo.Migrations.AddWorkflowSharing do
  use Ecto.Migration

  def change do
    # Add public field to workflows table
    alter table(:workflows) do
      add :public, :boolean, default: false, null: false
    end

    create index(:workflows, [:public])

    # Create workflow_shares table for sharing workflows with other users
    create table(:workflow_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false

      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_shares, [:user_id])
    create index(:workflow_shares, [:workflow_id])
    create unique_index(:workflow_shares, [:user_id, :workflow_id])
  end
end
