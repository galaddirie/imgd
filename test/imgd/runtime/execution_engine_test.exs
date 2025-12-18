defmodule Imgd.Runtime.ExecutionEngineTest do
  use Imgd.DataCase, async: true

  alias Imgd.Runtime.ExecutionEngine
  alias Imgd.Runtime.Engines.Runic, as: RunicEngine
  alias Imgd.Executions.Context

  describe "engine/0" do
    test "returns configured engine" do
      assert ExecutionEngine.engine() == RunicEngine
    end

    test "can be configured" do
      # This would be set in config/test.exs
      # config :imgd, :execution_engine, MyCustomEngine
      assert is_atom(ExecutionEngine.engine())
    end
  end

  describe "build/3 delegation" do
    setup do
      user = insert(:user)
      workflow = insert(:workflow, user: user)

      version =
        insert(:workflow_version,
          workflow: workflow,
          nodes: [
            %{id: "node_1", type_id: "debug", name: "Debug 1", config: %{}, position: %{}},
            %{id: "node_2", type_id: "debug", name: "Debug 2", config: %{}, position: %{}}
          ],
          connections: [
            %{
              id: "conn_1",
              source_node_id: "node_1",
              target_node_id: "node_2",
              source_output: "main",
              target_input: "main"
            }
          ]
        )

      execution = insert(:execution, workflow: workflow, workflow_version: version)

      context = %Context{
        execution_id: execution.id,
        workflow_id: workflow.id,
        workflow_version_id: version.id,
        trigger_type: :manual,
        trigger_data: %{},
        node_outputs: %{},
        variables: %{},
        current_node_id: nil,
        current_input: nil,
        metadata: %{}
      }

      %{version: version, context: context, execution: execution}
    end

    test "builds workflow via configured engine", %{
      version: version,
      context: context,
      execution: execution
    } do
      assert {:ok, _executable} = ExecutionEngine.build(version, context, execution)
    end

    test "builds without execution for preview mode", %{version: version, context: context} do
      assert {:ok, _executable} = ExecutionEngine.build(version, context, nil)
    end

    test "returns error for invalid workflow", %{context: context, execution: execution} do
      invalid_version = %Imgd.Workflows.WorkflowVersion{
        workflow_id: Ecto.UUID.generate(),
        version_tag: "1.0.0",
        nodes: [
          %{id: "a", type_id: "debug", name: "A", config: %{}, position: %{}},
          %{id: "b", type_id: "debug", name: "B", config: %{}, position: %{}}
        ],
        connections: [
          # Creates a cycle
          %{id: "1", source_node_id: "a", target_node_id: "b"},
          %{id: "2", source_node_id: "b", target_node_id: "a"}
        ]
      }

      assert {:error, {:cycle_detected, _}} =
               ExecutionEngine.build(invalid_version, context, execution)
    end
  end

  describe "execute/3" do
    setup do
      user = insert(:user)
      workflow = insert(:workflow, user: user)

      version =
        insert(:workflow_version,
          workflow: workflow,
          nodes: [
            %{
              id: "passthrough",
              type_id: "transform",
              name: "Passthrough",
              config: %{"operation" => "passthrough"},
              position: %{}
            }
          ],
          connections: []
        )

      execution = insert(:execution, workflow: workflow, workflow_version: version)

      context = %Context{
        execution_id: execution.id,
        workflow_id: workflow.id,
        workflow_version_id: version.id,
        trigger_type: :manual,
        trigger_data: %{},
        node_outputs: %{},
        variables: %{},
        current_node_id: nil,
        current_input: nil,
        metadata: %{}
      }

      # Start execution state for the test
      Imgd.Runtime.ExecutionState.start(execution.id)
      on_exit(fn -> Imgd.Runtime.ExecutionState.cleanup(execution.id) end)

      %{version: version, context: context, execution: execution}
    end

    test "executes workflow and returns results", %{
      version: version,
      context: context,
      execution: execution
    } do
      {:ok, executable} = ExecutionEngine.build(version, context, execution)
      input = %{"test" => "data"}

      assert {:ok, result} = ExecutionEngine.execute(executable, input, context)
      assert is_map(result.output)
      assert is_map(result.node_outputs)
      assert is_map(result.engine_logs)
    end
  end
end

defmodule Imgd.Runtime.Engines.RunicTest do
  @moduledoc """
  Tests specific to the Runic engine implementation.
  """
  use Imgd.DataCase, async: true

  alias Imgd.Runtime.Engines.Runic, as: RunicEngine

  describe "build_dag/2" do
    test "builds valid DAG" do
      nodes = [
        %{id: "a"},
        %{id: "b"},
        %{id: "c"}
      ]

      connections = [
        %{source_node_id: "a", target_node_id: "b"},
        %{source_node_id: "b", target_node_id: "c"}
      ]

      assert {:ok, graph} = RunicEngine.build_dag(nodes, connections)
      assert graph.adjacency["a"] == ["b"]
      assert graph.adjacency["b"] == ["c"]
      assert graph.reverse_adjacency["b"] == ["a"]
      assert graph.reverse_adjacency["c"] == ["b"]
    end

    test "rejects invalid connections" do
      nodes = [%{id: "a"}]
      connections = [%{source_node_id: "a", target_node_id: "nonexistent"}]

      assert {:error, {:invalid_connections, _}} = RunicEngine.build_dag(nodes, connections)
    end
  end

  describe "topological_sort/2" do
    test "sorts nodes in execution order" do
      nodes = [
        %{id: "c"},
        %{id: "a"},
        %{id: "b"}
      ]

      connections = [
        %{source_node_id: "a", target_node_id: "b"},
        %{source_node_id: "b", target_node_id: "c"}
      ]

      {:ok, graph} = RunicEngine.build_dag(nodes, connections)
      {:ok, sorted} = RunicEngine.topological_sort(graph, nodes)

      sorted_ids = Enum.map(sorted, & &1.id)
      assert Enum.find_index(sorted_ids, &(&1 == "a")) < Enum.find_index(sorted_ids, &(&1 == "b"))
      assert Enum.find_index(sorted_ids, &(&1 == "b")) < Enum.find_index(sorted_ids, &(&1 == "c"))
    end

    test "detects cycles" do
      nodes = [%{id: "a"}, %{id: "b"}]

      connections = [
        %{source_node_id: "a", target_node_id: "b"},
        %{source_node_id: "b", target_node_id: "a"}
      ]

      {:ok, graph} = RunicEngine.build_dag(nodes, connections)
      assert {:error, {:cycle_detected, _}} = RunicEngine.topological_sort(graph, nodes)
    end
  end
end
