defmodule Imgd.Runtime.RunicAdapter do
  @moduledoc """
  Bridges Imgd workflow definitions (Nodes/Connections) with the Runic execution engine.

  This adapter handles the conversion of a design-time workflow into a
  run-time Runic `%Workflow{}` struct, which acts as the single source
  of truth for execution state.
  """
  require Runic
  alias Runic.{Workflow, Component}
  alias Imgd.Nodes.Executors.Behaviour, as: ExecutorBehaviour
  alias Imgd.Executions.Execution

  @doc """
  Converts an Imgd workflow draft into a Runic Workflow.
  """
  def to_runic_workflow(source) do
    nodes = source.nodes
    connections = source.connections
    source_id = Map.get(source, :id) || Map.get(source, :workflow_id) || "unknown"

    # 1. Initialize empty Runic workflow
    wrk = Workflow.new(name: "execution_#{source_id}")

    # 2. Build the graph by connecting nodes
    # We process nodes and connect them to parents or :root.
    Enum.reduce(nodes, wrk, fn node, acc ->
      # Create the Runic step function
      step = create_step(node)

      # Find incoming connections for this node
      incoming = Enum.filter(connections, &(&1.target_node_id == node.id))

      if incoming == [] do
        # Entry point node - connects to :root
        Component.connect(step, :root, acc)
      else
        # Connect to each parent node by name
        Enum.reduce(incoming, acc, fn conn, acc_inner ->
          Component.connect(step, conn.source_node_id, acc_inner)
        end)
      end
    end)
  end

  @doc """
  Creates a Runic step from an Imgd node.
  """
  def create_step(node) do
    Runic.step(
      fn input ->
        execute_node(node, input)
      end,
      name: node.id
    )
  end

  defp execute_node(node, input) do
    # Resolve the executor for this node type
    executor = ExecutorBehaviour.resolve!(node.type_id)

    # Note: Runic passes the production(s) of parent nodes as 'input'.
    # If multiple parents, input is a list of results.

    # We need a surrogate execution record for now.
    # The actual Server will enrich this later.
    execution = %Execution{
      workflow_id: node.id,
      status: :running
    }

    # TODO: Handle expression evaluation in node.config using Runic's state.

    case executor.execute(node.config, input, execution) do
      {:ok, result} ->
        result

      {:error, reason} ->
        # Runic handles errors by letting them propagate or using hooks.
        # We throw a controlled error that the Server can catch.
        throw({:node_error, node.id, reason})

      {:skip, _reason} ->
        # Skip logic - in Runic, returning nil or a specific marker.
        nil
    end
  end
end
