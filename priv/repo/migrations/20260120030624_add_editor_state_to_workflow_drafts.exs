defmodule Imgd.Repo.Migrations.AddEditorStateToWorkflowDrafts do
  use Ecto.Migration

  def up do
    alter table(:workflow_drafts) do
      add :editor_state, :map, null: false, default: %{}
    end

    execute("""
    UPDATE workflow_drafts
    SET editor_state = COALESCE(
      settings->'editor_state',
      jsonb_strip_nulls(
        jsonb_build_object(
          'pinned_outputs', settings->'pinned_outputs',
          'disabled_steps', settings->'disabled_steps',
          'disabled_mode', settings->'disabled_mode'
        )
      )
    )
    WHERE settings ? 'editor_state'
       OR settings ? 'pinned_outputs'
       OR settings ? 'disabled_steps'
       OR settings ? 'disabled_mode';
    """)
  end

  def down do
    execute("""
    UPDATE workflow_drafts
    SET settings = jsonb_set(
      COALESCE(settings, '{}'::jsonb),
      '{editor_state}',
      COALESCE(editor_state, '{}'::jsonb),
      true
    )
    """)

    alter table(:workflow_drafts) do
      remove :editor_state
    end
  end
end
