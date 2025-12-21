defmodule Imgd.Collaboration.EditSession.OperationsTest do
  use Imgd.DataCase, async: true

  alias Imgd.Collaboration.EditSession.Operations
  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Node, Connection}

  describe "validate/2" do
    setup do
      # Create a basic draft with nodes and connections
      draft = %WorkflowDraft{
        workflow_id: Ecto.UUID.generate(),
        nodes: [
          %Node{
            id: "node_1",
            type_id: "http_request",
            name: "HTTP Request",
            position: %{x: 100, y: 100}
          },
          %Node{id: "node_2", type_id: "debug", name: "Debug Node", position: %{x: 300, y: 100}}
        ],
        connections: []
      }

      %{draft: draft}
    end

    test "validates add_node operation successfully", %{draft: draft} do
      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "node_3",
            type_id: "debug",
            name: "Debug Node",
            position: %{x: 500, y: 100}
          }
        }
      }

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects add_node with duplicate id", %{draft: draft} do
      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            # Already exists
            id: "node_1",
            type_id: "text_formatter",
            name: "Text Formatter"
          }
        }
      }

      assert {:error, {:node_already_exists, "node_1"}} = Operations.validate(draft, operation)
    end

    test "rejects add_node with invalid node type", %{draft: draft} do
      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "node_3",
            type_id: "invalid_type",
            name: "Invalid Node"
          }
        }
      }

      assert {:error, :invalid_node_type} = Operations.validate(draft, operation)
    end

    test "validates remove_node operation successfully", %{draft: draft} do
      operation = %{
        type: :remove_node,
        payload: %{node_id: "node_1"}
      }

      assert :ok = Operations.validate(draft, operation)
    end

    test "rejects remove_node for non-existent node", %{draft: draft} do
      operation = %{
        type: :remove_node,
        payload: %{node_id: "node_999"}
      }

      assert {:error, {:node_not_found, "node_999"}} = Operations.validate(draft, operation)
    end

    test "validates add_connection operation successfully", %{draft: draft} do
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            source_node_id: "node_1",
            source_output: "main",
            target_node_id: "node_2",
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
            %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"}
          ]
      }

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            # Duplicate
            id: "conn_1",
            source_node_id: "node_1",
            target_node_id: "node_2"
          }
        }
      }

      assert {:error, {:connection_already_exists, "conn_1"}} =
               Operations.validate(draft_with_conn, operation)
    end

    test "rejects add_connection with non-existent source node", %{draft: draft} do
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            # Doesn't exist
            source_node_id: "node_999",
            target_node_id: "node_2"
          }
        }
      }

      assert {:error, {:source_node_not_found, "node_999"}} =
               Operations.validate(draft, operation)
    end

    test "rejects add_connection that creates a cycle", %{draft: draft} do
      # Create a draft with a cycle: node_1 -> node_2 -> node_1
      draft_with_cycle = %{
        draft
        | nodes:
            draft.nodes ++
              [
                %Node{id: "node_3", type_id: "text_formatter", name: "Node 3"}
              ],
          connections: [
            %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"},
            %Connection{id: "conn_2", source_node_id: "node_2", target_node_id: "node_3"}
          ]
      }

      # Try to add node_3 -> node_1, creating a cycle
      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_3",
            source_node_id: "node_3",
            target_node_id: "node_1"
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
            source_node_id: "node_1",
            # Same node
            target_node_id: "node_1"
          }
        }
      }

      assert {:error, :self_loop_not_allowed} = Operations.validate(draft, operation)
    end

    test "validates remove_connection operation successfully", %{draft: draft} do
      draft_with_conn = %{
        draft
        | connections: [
            %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"}
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
        %{type: :pin_node_output, payload: %{node_id: "node_1", output_data: %{}}},
        %{type: :unpin_node_output, payload: %{node_id: "node_1"}},
        %{type: :disable_node, payload: %{node_id: "node_1"}},
        %{type: :enable_node, payload: %{node_id: "node_1"}}
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
        nodes: [
          %Node{
            id: "node_1",
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

    test "applies add_node operation", %{draft: draft} do
      operation = %{
        type: :add_node,
        payload: %{
          node: %{
            id: "node_2",
            type_id: "debug",
            name: "JSON Parser",
            position: %{x: 300, y: 100}
          }
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      assert length(new_draft.nodes) == 2
      assert Enum.find(new_draft.nodes, &(&1.id == "node_2")).name == "JSON Parser"
    end

    test "applies remove_node operation", %{draft: draft} do
      operation = %{type: :remove_node, payload: %{node_id: "node_1"}}

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      assert new_draft.nodes == []
    end

    test "applies remove_node operation with connections", %{draft: draft} do
      draft_with_connections = %{
        draft
        | nodes:
            draft.nodes ++
              [
                %Node{id: "node_2", type_id: "debug", name: "Debug Node"}
              ],
          connections: [
            %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"}
          ]
      }

      operation = %{type: :remove_node, payload: %{node_id: "node_1"}}

      assert {:ok, new_draft} = Operations.apply(draft_with_connections, operation)
      # Both node and connection should be removed
      assert length(new_draft.nodes) == 1
      assert new_draft.nodes |> hd() |> Map.get(:id) == "node_2"
      assert new_draft.connections == []
    end

    test "applies update_node_config with JSON patch", %{draft: draft} do
      operation = %{
        type: :update_node_config,
        payload: %{
          node_id: "node_1",
          patch: [
            %{"op" => "replace", "path" => "/url", "value" => "https://new-api.example.com"},
            %{"op" => "add", "path" => "/method", "value" => "POST"}
          ]
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      node = Enum.find(new_draft.nodes, &(&1.id == "node_1"))
      assert node.config["url"] == "https://new-api.example.com"
      assert node.config["method"] == "POST"
    end

    test "applies update_node_position", %{draft: draft} do
      operation = %{
        type: :update_node_position,
        payload: %{
          node_id: "node_1",
          position: %{x: 200, y: 150}
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      node = Enum.find(new_draft.nodes, &(&1.id == "node_1"))
      assert node.position == %{x: 200, y: 150}
    end

    test "applies update_node_metadata", %{draft: draft} do
      operation = %{
        type: :update_node_metadata,
        payload: %{
          node_id: "node_1",
          changes: %{name: "Updated HTTP Request", notes: "Updated notes"}
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft, operation)
      node = Enum.find(new_draft.nodes, &(&1.id == "node_1"))
      assert node.name == "Updated HTTP Request"
      assert node.notes == "Updated notes"
    end

    test "applies add_connection operation", %{draft: draft} do
      draft_with_node = %{
        draft
        | nodes:
            draft.nodes ++
              [
                %Node{id: "node_2", type_id: "debug", name: "Debug Node"}
              ]
      }

      operation = %{
        type: :add_connection,
        payload: %{
          connection: %{
            id: "conn_1",
            source_node_id: "node_1",
            target_node_id: "node_2"
          }
        }
      }

      assert {:ok, new_draft} = Operations.apply(draft_with_node, operation)
      assert length(new_draft.connections) == 1
      conn = hd(new_draft.connections)
      assert conn.id == "conn_1"
      assert conn.source_node_id == "node_1"
      assert conn.target_node_id == "node_2"
    end

    test "applies remove_connection operation", %{draft: draft} do
      draft_with_conn = %{
        draft
        | connections: [
            %Connection{id: "conn_1", source_node_id: "node_1", target_node_id: "node_2"}
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
