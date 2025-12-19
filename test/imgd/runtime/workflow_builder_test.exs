defmodule Imgd.Runtime.WorkflowBuilderTest do
  use Imgd.DataCase, async: true

  alias Imgd.Runtime.WorkflowBuilder
  alias Imgd.Runtime.Engines.Runic, as: RunicEngine

  describe "engine/0" do
    test "returns configured engine" do
      assert WorkflowBuilder.engine() == RunicEngine
    end

    test "can be configured" do
      # This would be set in config/test.exs
      # config :imgd, :execution_engine, MyCustomEngine
      assert is_atom(WorkflowBuilder.engine())
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

      %{version: version, execution: execution}
    end

    test "builds workflow via configured engine", %{
      version: version,
      execution: execution
    } do
      assert {:ok, _executable} = WorkflowBuilder.build(version, execution)
    end

    test "builds without execution for preview mode", %{version: version} do
      assert {:ok, _executable} = WorkflowBuilder.build(version, nil)
    end

    test "returns error for invalid workflow", %{execution: execution} do
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
               WorkflowBuilder.build(invalid_version, execution)
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

      # Start execution state for the test
      Imgd.Runtime.ExecutionState.start(execution.id)
      on_exit(fn -> Imgd.Runtime.ExecutionState.cleanup(execution.id) end)

      %{version: version, execution: execution}
    end

    test "executes workflow and returns results", %{
      version: version,
      execution: execution
    } do
      {:ok, executable} = WorkflowBuilder.build(version, execution)
      input = %{"test" => "data"}

      assert {:ok, result} = WorkflowBuilder.execute(executable, input, execution)
      assert is_map(result.output)
      assert is_map(result.node_outputs)
      assert is_map(result.engine_logs)
    end
  end
end
