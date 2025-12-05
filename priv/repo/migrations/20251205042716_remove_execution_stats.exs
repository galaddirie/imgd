defmodule Imgd.Repo.Migrations.RemoveExecutionStats do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      remove :stats, :map
    end
  end
end
