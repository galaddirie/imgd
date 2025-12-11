defmodule Imgd.Repo.Migrations.CreateNodeExecutions do
  use Ecto.Migration

  def change do
    create table(:node_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :execution_id, references(:executions, on_delete: :delete_all, type: :binary_id),
        null: false

      # Which node in the workflow definition
      add :node_id, :string, null: false
      add :node_type_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      # Data flowing through this node
      add :input_data, :jsonb
      add :output_data, :jsonb
      add :error, :jsonb
      # Extensible metadata
      add :metadata, :jsonb, null: false, default: "{}"
      # Timing
      add :queued_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      # Retry tracking
      add :attempt, :integer, null: false, default: 1
      add :retry_of_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create index(:node_executions, [:execution_id])
    create index(:node_executions, [:execution_id, :node_id])
    create index(:node_executions, [:status])
    create index(:node_executions, [:node_type_id])
    create index(:node_executions, [:retry_of_id])
    # For ordering node executions within an execution
    create index(:node_executions, [:execution_id, :inserted_at])
  end
end
