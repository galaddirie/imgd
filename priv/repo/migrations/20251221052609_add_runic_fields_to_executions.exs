defmodule Imgd.Repo.Migrations.AddRunicFieldsToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :runic_log, :jsonb
      add :runic_snapshot, :binary
    end
  end
end
