defmodule Imgd.Collaboration.EditSession.OperationsTest do
  use Imgd.DataCase, async: true

  alias Imgd.Collaboration.EditSession.Operations
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Step, Connection}

  describe "validate/2" do
    setup do
      # Create a basic draft with steps and connections
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          %Step{
            id: "step_1",
            type_id: "http_request",
            name: "HTTP Request",
            position: %{x: 100, y: 100}
          },
          %Step{id: "step_2", type_id: "debug", name: "Debug Step", position: %{x: 300, y: 100}}
        ],
        connections: []
      }

      %{draft: draft}
    end

    test "validates add_step operation successfully", %{draft: draft} do
      operation = %{
        type: :add_step,
        payload: %{
          step: %{
            id: "step_3",
            type_id: "debug",
            name: "Debug Step",
            position: %{x: 500, y: 100}
          }
        }
      }

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects add_step with duplicate id", %{draft: draft} do
      operation = %{
        type: :add_step,
        payload: %{
          step: %{
            # Already exists
            id: "step_1",
            type_id: "text_formatter",
            name: "Text Formatter"
          }
        }
      }

      assert {:error, {:step_already_exists, "step_1"}} = Operations.validate(draft, operation)
    end

    test "rejects add_step with invalid step type", %{draft: draft} do
      operation = %{
        type: :add_step,
        payload: %{
          step: %{
            id: "step_3",
            type_id: "invalid_type",
            name: "Invalid Step"
          }
        }
      }

      assert {:error, :invalid_step_type} = Operations.validate(draft, operation)
    end

    test "validates remove_step operation successfully", %{draft: draft} do
      operation = %{
        type: :remove_step,
        payload: %{step_id: "step_1"}
      }

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects remove_step for non-existent step", %{draft: draft} do
      operation = %{
        type: :remove_step,
        payload: %{step_id: "step_999"}
      }

      assert {:error, {:step_not_found, "step_999"}} = Operations.validate(draft, operation)
    end

    test "validates add_connection operation successfully", %{draft: draft} do
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            source_step_id: "step_1",
            source_output: "main",
            target_step_id: "step_2",
            target_input: "main"
          }
        }
      }

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects add_connection with duplicate id", %{draft: draft} do
      draft_with_conn = %{
        draft
        | connections: [
            %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
          ]
      }

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            # Duplicate
            id: "conn_1",
            source_step_id: "step_1",
            target_step_id: "step_2"
          }
        }
      }

      assert {:error, {:connection_already_exists, "conn_1"}} =
               Operations.validate(draft_with_conn, operation)
    end

    test "rejects add_connection with non-existent source step", %{draft: draft} do
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            # Doesn't exist
            source_step_id: "step_999",
            target_step_id: "step_2"
          }
        }
      }

      assert {:error, {:source_step_not_found, "step_999"}} =
               Operations.validate(draft, operation)
    end

    test "rejects add_connection that creates a cycle", %{draft: draft} do
      # Create a draft with a cycle: step_1 -> step_2 -> step_1
      draft_with_cycle = %{
        draft
        | steps:
            draft.steps ++
              [
                %Step{id: "step_3", type_id: "text_formatter", name: "Step 3"}
              ],
          connections: [
            %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"},
            %Connection{id: "conn_2", source_step_id: "step_2", target_step_id: "step_3"}
          ]
      }

      # Try to add step_3 -> step_1, creating a cycle
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_3",
            source_step_id: "step_3",
            target_step_id: "step_1"
          }
        }
      }

      assert {:error, :would_create_cycle} = Operations.validate(draft_with_cycle, operation)
    end

    test "rejects self-loop connections", %{draft: draft} do
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            source_step_id: "step_1",
            # Same step
            target_step_id: "step_1"
          }
        }
      }

      assert {:error, :self_loop_not_allowed} = Operations.validate(draft, operation)
    end

    test "validates remove_connection operation successfully", %{draft: draft} do
      draft_with_conn = %{
        draft
        | connections: [
            %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
          ]
      }

      operation = %{
        type: :remove_connection,
        payload: %{connection_id: "conn_1"}
      }

      assert :ok = Operations.validate(draft_with_conn, operation)
    end

    test "rejects remove_connection for non-existent connection", %{draft: draft} do
      operation = %{
        type: :remove_connection,
        payload: %{connection_id: "conn_999"}
      }

      assert {:error, {:connection_not_found, "conn_999"}} = Operations.validate(draft, operation)
    end

    test "validates editor operations without draft validation", %{draft: draft} do
      # Editor operations don't need draft validation
      operations = [
        %{type: :pin_step_output, payload: %{step_id: "step_1", output_data: %{}}},
        %{type: :unpin_step_output, payload: %{step_id: "step_1"}},
        %{type: :disable_step, payload: %{step_id: "step_1"}},
        %{type: :enable_step, payload: %{step_id: "step_1"}}
      ]

      for operation <- operations do
        assert :ok = Operations.validate(draft, operation)
      end
    end
  end

  describe "apply/2" do
    setup do
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        steps: [
          %Step{
            id: "step_1",
            type_id: "http_request",
            name: "HTTP Request",
            position: %{x: 100, y: 100},
            config: %{url: "https://api.example.com"}
          }
        ],
        connections: []
      }

      %{draft: draft}
    end

    test "applies add_step operation", %{draft: draft} do
      operation = %{
        type: :add_step,
        payload: %{
          step: %{
            id: "step_2",
            type_id: "debug",
            name: "JSON Parser",
            position: %{x: 300, y: 100}
          }
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      assert length(new_draft.steps) == 2
      assert Enum.find(new_draft.steps, &(&1.id == "step_2")).name == "JSON Parser"
    end

    test "applies remove_step operation", %{draft: draft} do
      operation = %{type: :remove_step, payload: %{step_id: "step_1"}}

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      assert new_draft.steps == []
    end

    test "applies remove_step operation with connections", %{draft: draft} do
      draft_with_connections = %{
        draft
        | steps:
            draft.steps ++
              [
                %Step{id: "step_2", type_id: "debug", name: "Debug Step"}
              ],
          connections: [
            %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
          ]
      }

      operation = %{type: :remove_step, payload: %{step_id: "step_1"}}

      assert {:ok, new_draft} = Operations.apply(draft_with_connections, operation)
      # Both step and connection should be removed
      assert length(new_draft.steps) == 1
      assert new_draft.steps |> hd() |> Map.get(:id) == "step_2"
      assert new_draft.connections == []
    end

    test "applies update_step_config with JSON patch", %{draft: draft} do
      operation = %{
        type: :update_step_config,
        payload: %{
          step_id: "step_1",
          patch: [
            %{"op" => "replace", "path" => "/url", "value" => "https://new-api.example.com"},
            %{"op" => "add", "path" => "/method", "value" => "POST"}
          ]
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      step = Enum.find(new_draft.steps, &(&1.id == "step_1"))
      assert step.config["url"] == "https://new-api.example.com"
      assert step.config["method"] == "POST"
    end

    test "applies update_step_position", %{draft: draft} do
      operation = %{
        type: :update_step_position,
        payload: %{
          step_id: "step_1",
          position: %{x: 200, y: 150}
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      step = Enum.find(new_draft.steps, &(&1.id == "step_1"))
      assert step.position == %{x: 200, y: 150}
    end

    test "applies update_step_metadata", %{draft: draft} do
      operation = %{
        type: :update_step_metadata,
        payload: %{
          step_id: "step_1",
          changes: %{name: "Updated HTTP Request", notes: "Updated notes"}
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      step = Enum.find(new_draft.steps, &(&1.id == "step_1"))
      assert step.name == "Updated HTTP Request"
      assert step.notes == "Updated notes"
    end

    test "applies update_step_metadata including config", %{draft: draft} do
      operation = %{
        type: :update_step_metadata,
        payload: %{
          step_id: "step_1",
          changes: %{
            name: "Updated Name",
            config: %{"url" => "https://updated.com"}
          }
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      step = Enum.find(new_draft.steps, &(&1.id == "step_1"))
      assert step.name == "Updated Name"
      assert step.config["url"] == "https://updated.com"
    end

    test "applies add_connection operation", %{draft: draft} do
      draft_with_step = %{
        draft
        | steps:
            draft.steps ++
              [
                %Step{id: "step_2", type_id: "debug", name: "Debug Step"}
              ]
      }

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            source_step_id: "step_1",
            target_step_id: "step_2"
          }
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft_with_step, operation)
      assert length(new_draft.connections) == 1
      conn = hd(new_draft.connections)
      assert conn.id == "conn_1"
      assert conn.source_step_id == "step_1"
      assert conn.target_step_id == "step_2"
    end

    test "applies remove_connection operation", %{draft: draft} do
      draft_with_conn = %{
        draft
        | connections: [
            %Connection{id: "conn_1", source_step_id: "step_1", target_step_id: "step_2"}
          ]
      }

      operation = %{type: :remove_connection, payload: %{connection_id: "conn_1"}}

      assert {:ok, new_draft} = Operations.apply(draft_with_conn, operation)
      assert new_draft.connections == []
    end
  end

  describe "JSON patch operations" do
    test "handles replace operations" do
      config = %{"url" => "old.com", "method" => "GET"}
      patches = [%{"op" => "replace", "path" => "/url", "value" => "new.com"}]

      result = Operations.apply_json_patch(config, patches)
      assert result["url"] == "new.com"
      assert result["method"] == "GET"
    end

    test "handles add operations" do
      config = %{"url" => "api.com"}
      patches = [%{"op" => "add", "path" => "/method", "value" => "POST"}]

      result = Operations.apply_json_patch(config, patches)
      assert result["method"] == "POST"
      assert result["url"] == "api.com"
    end

    test "handles remove operations" do
      config = %{"url" => "api.com", "method" => "GET"}
      patches = [%{"op" => "remove", "path" => "/method"}]

      result = Operations.apply_json_patch(config, patches)
      assert result["url"] == "api.com"
      refute Map.has_key?(result, "method")
    end

    test "handles nested paths" do
      config = %{"auth" => %{"token" => "old_token"}}
      patches = [%{"op" => "replace", "path" => "/auth/token", "value" => "new_token"}]

      result = Operations.apply_json_patch(config, patches)
      assert result["auth"]["token"] == "new_token"
    end
  end
end
