defmodule Imgd.Repo.Migrations.AddPublishedVersionToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :published_version_id, references(:workflow_versions, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:workflows, [:published_version_id])
  end
end
