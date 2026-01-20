defmodule Imgd.Collaboration.EditSession.InversionTest do
  use Imgd.DataCase, async: true

  alias Imgd.Collaboration.EditSession.Inversion
  alias Imgd.Collaboration.EditorState
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Connection, NodeGroup, Step}

  setup do
    draft = %WorkflowDraft{
      workflow_id: Ecto.UUID.generate(),
      steps: [
        %Step{
          id: "step_1",
          type_id: "http_request",
          name: "HTTP Request",
          config: %{"url" => "https://example.com"},
          position: %{x: 100, y: 100}
        },
        %Step{
          id: "step_2",
          type_id: "debug",
          name: "Debug Step",
          config: %{},
          position: %{x: 300, y: 100}
        }
      ],
      connections: [
        %Connection{
          id: "conn_1",
          source_step_id: "step_1",
          target_step_id: "step_2",
          source_output: "main",
          target_input: "main"
        }
      ],
      groups: [
        %NodeGroup{
          id: "group_1",
          name: "Group 1",
          step_ids: ["step_1"],
          output_step_id: "step_1",
          position: %{x: 0, y: 0},
          collapsed: false
        }
      ]
    }

    editor_state = %EditorState{
      workflow_id: draft.workflow_id,
      pinned_outputs: %{"step_1" => %{}}
    }

    %{draft: draft, editor_state: editor_state}
  end

  test "computes inverse for add_step", %{draft: draft, editor_state: editor_state} do
    operation = %{type: :add_step, payload: %{step: %{id: "step_3"}}}

    assert {:ok, [%{type: :remove_step, payload: %{step_id: "step_3"}}]} =
             Inversion.compute_inverse(draft, editor_state, operation)
  end

  test "computes inverse for remove_step with connections and group", %{
    draft: draft,
    editor_state: editor_state
  } do
    operation = %{type: :remove_step, payload: %{step_id: "step_1"}}

    assert {:ok, inverse_ops} = Inversion.compute_inverse(draft, editor_state, operation)

    assert [%{type: :add_step, payload: %{step: step, group_id: "group_1"}} | rest] =
             inverse_ops

    assert step.id == "step_1"
    assert Enum.any?(rest, &(&1.type == :add_connection))
  end

  test "computes inverse for update_step_config", %{draft: draft, editor_state: editor_state} do
    operation = %{
      type: :update_step_config,
      payload: %{
        step_id: "step_1",
        patch: [%{"op" => "replace", "path" => "/url", "value" => "https://new.example.com"}]
      }
    }

    assert {:ok, [%{type: :update_step_config, payload: payload}]} =
             Inversion.compute_inverse(draft, editor_state, operation)

    assert payload.step_id == "step_1"

    assert [%{"op" => "replace", "path" => "/url", "value" => "https://example.com"}] =
             payload.patch
  end

  test "computes inverse for unpin_step_output", %{draft: draft, editor_state: editor_state} do
    operation = %{type: :unpin_step_output, payload: %{step_id: "step_1"}}

    assert {:ok, [%{type: :pin_step_output, payload: payload}]} =
             Inversion.compute_inverse(draft, editor_state, operation)

    assert payload.step_id == "step_1"
    assert payload.output_data == %{}
  end
end
