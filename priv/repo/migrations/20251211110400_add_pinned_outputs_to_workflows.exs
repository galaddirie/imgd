defmodule Imgd.Repo.Migrations.AddPinnedOutputsToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :pinned_outputs, :map, default: %{}
    end
  end
end
