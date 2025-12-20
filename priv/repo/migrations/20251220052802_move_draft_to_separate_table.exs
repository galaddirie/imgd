defmodule Imgd.Repo.Migrations.MoveDraftToSeparateTable do
  use Ecto.Migration

  def up do
    # 1. Create the workflow_drafts table
    create table(:workflow_drafts, primary_key: false) do
      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :nodes, :jsonb, null: false, default: "[]"
      add :connections, :jsonb, null: false, default: "[]"
      add :triggers, :jsonb, null: false, default: "[]"
      add :settings, :jsonb, null: false, default: "{}"

      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # 2. Add draft_id to pinned_outputs and update relationships
    # Note: pinned_outputs already exists from previous migration
    alter table(:pinned_outputs) do
      add :workflow_draft_id,
          references(:workflow_drafts,
            column: :workflow_id,
            type: :binary_id,
            on_delete: :delete_all
          )
    end

    # 3. Migrate existing draft data from workflows to workflow_drafts
    execute """
    INSERT INTO workflow_drafts (workflow_id, nodes, connections, triggers, settings, inserted_at, updated_at)
    SELECT id, nodes, connections, triggers, settings, NOW(), NOW()
    FROM workflows
    """

    # 4. Update pinned_outputs to point to drafts
    execute """
    UPDATE pinned_outputs
    SET workflow_draft_id = workflow_id
    """

    # 5. Make workflow_draft_id mandatory on pinned_outputs and remove workflow_id link
    alter table(:pinned_outputs) do
      modify :workflow_draft_id, :binary_id, null: false
      remove :workflow_id
    end

    # 6. Remove draft-related columns from workflows
    alter table(:workflows) do
      remove :nodes
      remove :connections
      remove :triggers
      remove :settings
    end
  end

  def down do
    alter table(:workflows) do
      add :nodes, :jsonb, null: false, default: "[]"
      add :connections, :jsonb, null: false, default: "[]"
      add :triggers, :jsonb, null: false, default: "[]"
      add :settings, :jsonb, null: false, default: "{}"
    end

    execute """
    UPDATE workflows w
    SET nodes = d.nodes,
        connections = d.connections,
        triggers = d.triggers,
        settings = d.settings
    FROM workflow_drafts d
    WHERE w.id = d.workflow_id
    """

    alter table(:pinned_outputs) do
      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all)
    end

    execute """
    UPDATE pinned_outputs
    SET workflow_id = workflow_draft_id
    """

    alter table(:pinned_outputs) do
      modify :workflow_id, :binary_id, null: false
      remove :workflow_draft_id
    end

    drop table(:workflow_drafts)
  end
end
