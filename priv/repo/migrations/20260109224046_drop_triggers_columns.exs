defmodule Imgd.Repo.Migrations.DropTriggersColumns do
  use Ecto.Migration

  def change do
    alter table(:workflow_versions) do
      remove :triggers
    end

    alter table(:workflow_drafts) do
      remove :triggers
    end
  end
end
