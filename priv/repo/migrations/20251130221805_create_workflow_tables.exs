defmodule Imgd.Repo.Migrations.CreateWorkflowTables do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :version, :integer, default: 1, null: false
      add :status, :string, default: "draft", null: false
      add :definition, :map
      add :definition_hash, :integer
      add :trigger_config, :map, default: %{"type" => "manual", "config" => %{}}

      add :settings, :map,
        default: %{
          "timeout_ms" => 300_000,
          "max_retries" => 3,
          "checkpoint_strategy" => "generation",
          "checkpoint_interval_ms" => 60_000
        }

      add :published_at, :utc_datetime_usec
      add :user_id, references(:users, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflows, [:name])
    create index(:workflows, [:user_id])
    create index(:workflows, [:status])

    create table(:workflow_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :integer, null: false
      add :definition, :map, null: false
      add :definition_hash, :integer
      add :change_summary, :text
      add :published_by, references(:users, on_delete: :nothing, type: :binary_id)

      add :workflow_id, references(:workflows, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:workflow_versions, [:workflow_id, :version])
    create index(:workflow_versions, [:published_by])

    create table(:executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_version, :integer, null: false
      add :status, :string, default: "pending", null: false
      add :trigger_type, :string, default: "manual", null: false
      add :input, :map
      add :output, :map
      add :error, :map
      add :current_generation, :integer, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      add :stats, :map,
        default: %{
          "steps_completed" => 0,
          "steps_failed" => 0,
          "steps_skipped" => 0,
          "total_duration_ms" => 0,
          "retries" => 0
        }

      add :triggered_by_user_id, references(:users, on_delete: :nothing, type: :binary_id)
      add :workflow_id, references(:workflows, on_delete: :nothing, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:executions, [:workflow_id])
    create index(:executions, [:status])
    create index(:executions, [:triggered_by_user_id])
    create index(:executions, [:expires_at])

    create table(:execution_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :generation, :integer, null: false
      add :workflow_state, :binary, null: false
      add :pending_runnables, {:array, :map}, default: []
      add :accumulator_states, :map, default: %{}
      add :completed_step_hashes, {:array, :integer}, default: []
      add :reason, :string, default: "generation", null: false
      add :is_current, :boolean, default: true
      add :size_bytes, :integer

      add :execution_id, references(:executions, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:execution_checkpoints, [:execution_id])
    create index(:execution_checkpoints, [:is_current])
    create index(:execution_checkpoints, [:generation])

    create table(:execution_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :step_hash, :integer, null: false
      add :step_name, :string, null: false
      add :step_type, :string, null: false
      add :generation, :integer, null: false
      add :status, :string, default: "pending", null: false
      add :input_fact_hash, :integer
      add :output_fact_hash, :integer
      add :parent_step_hash, :integer
      add :input_snapshot, :map
      add :output_snapshot, :map
      add :error, :map
      add :logs, :text
      add :duration_ms, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :attempt, :integer, default: 1
      add :max_attempts, :integer, default: 1
      add :next_retry_at, :utc_datetime_usec
      add :idempotency_key, :string

      add :execution_id, references(:executions, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:execution_steps, [:execution_id])
    create index(:execution_steps, [:step_hash])
    create index(:execution_steps, [:status])
    create index(:execution_steps, [:next_retry_at])
    create unique_index(:execution_steps, [:execution_id, :step_hash, :input_fact_hash, :attempt])
  end
end
