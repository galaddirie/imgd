defmodule Imgd.Repo.Migrations.AddOutputItemCountToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :output_item_count, :integer
    end
  end
end
