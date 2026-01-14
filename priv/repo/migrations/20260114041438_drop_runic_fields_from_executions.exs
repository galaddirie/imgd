defmodule Imgd.Repo.Migrations.DropRunicFieldsFromExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      remove :runic_log
      remove :runic_snapshot
    end
  end
end
