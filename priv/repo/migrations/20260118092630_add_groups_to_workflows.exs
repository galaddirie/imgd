defmodule Imgd.Repo.Migrations.AddGroupsToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflow_drafts) do
      add :groups, :map
    end

    alter table(:workflow_versions) do
      add :groups, :map
    end
  end
end
