defmodule Imgd.Repo.Migrations.DropExecutionCheckpoints do
  use Ecto.Migration

  def change do
    drop_if_exists table(:execution_checkpoints)
  end
end
