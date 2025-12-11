defmodule Imgd.Repo.Migrations.CreateExecutions do
  use Ecto.Migration

  def change do
    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      add :workflow_version_id,
          references(:workflow_versions, on_delete: :restrict, type: :binary_id),
          null: false

      add :status, :string, null: false, default: "pending"
      # Embedded schemas stored as JSONB
      add :trigger, :jsonb, null: false
      add :metadata, :jsonb
      # Runic integration - event logs
      add :runic_build_log, :jsonb, null: false, default: "[]"
      add :runic_reaction_log, :jsonb, null: false, default: "[]"
      # Accumulated node outputs
      add :context, :jsonb, null: false, default: "{}"
      # Final output and error info
      add :output, :jsonb
      add :error, :jsonb
      # For paused executions awaiting callback
      add :waiting_for, :jsonb
      # Timing
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :triggered_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:executions, [:workflow_id])
    create index(:executions, [:workflow_version_id])
    create index(:executions, [:status])
    create index(:executions, [:workflow_id, :status])
    create index(:executions, [:started_at])
    create index(:executions, [:triggered_by_user_id])
    # For cursor-based pagination
    create index(:executions, [:workflow_id, :started_at])
  end
end
