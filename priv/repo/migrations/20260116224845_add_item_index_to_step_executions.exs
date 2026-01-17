defmodule Imgd.Repo.Migrations.AddItemIndexToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      # Fan-out item tracking
      # NULL = single-item step (backwards compatible)
      # 0, 1, 2, ... = individual item within a fan-out batch
      add :item_index, :integer

      # Total items in batch (set on all records in a fan-out)
      # NULL for single-item steps
      add :items_total, :integer
    end

    # Index for efficient grouping queries (e.g., all items for a step)
    create index(:step_executions, [:execution_id, :step_id, :item_index])

    # Unique constraint for upserts - use COALESCE to handle NULLs
    # Includes attempt to allow retries with the same step/item but different attempt
    create unique_index(
             :step_executions,
             [:execution_id, :step_id, "COALESCE(item_index, -1)", :attempt],
             name: :step_executions_execution_step_item_unique
           )
  end
end
