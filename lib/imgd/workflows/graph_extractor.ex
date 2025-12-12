defmodule Imgd.Workflows.GraphExtractor do
  @moduledoc """
  Builds lightweight graph data for the workflow graph LiveComponent.

  The extractor normalizes workflow nodes and connections, applies a small amount
  of validation, and returns layout coordinates so the SVG renderer can place
  nodes consistently even when explicit positions are missing.
  """

  alias Imgd.Nodes
  alias Imgd.Nodes.Type
  alias Imgd.Workflows.{Workflow, WorkflowVersion}
  alias Imgd.Workflows.Embeds.{Connection, Node}

  @type graph_data :: %{
          nodes: [map()],
          edges: [map()],
          layout: %{optional(String.t()) => {number(), number(), number(), number()}}
        }

  @node_width 200
  @node_height 96

  @spec extract(Workflow.t() | WorkflowVersion.t() | map()) ::
          {:ok, graph_data()} | {:error, term()}
  def extract(%Workflow{} = workflow), do: do_extract(workflow.nodes, workflow.connections)
  def extract(%WorkflowVersion{} = version), do: do_extract(version.nodes, version.connections)

  def extract(%{nodes: nodes, connections: connections})
      when is_list(nodes) and is_list(connections),
      do: do_extract(nodes, connections)

  def extract(_), do: {:error, :invalid_workflow}

  defp do_extract(nodes, connections) do
    normalized_nodes = Enum.map(nodes, &normalize_node/1)
    node_ids = MapSet.new(normalized_nodes, & &1.id)

    with :ok <- ensure_node_ids(normalized_nodes),
         :ok <- validate_connections(node_ids, connections) do
      layout = build_layout(normalized_nodes)
      edges = Enum.map(connections, &normalize_edge/1)

      {:ok,
       %{
         nodes: normalized_nodes,
         edges: edges,
         layout: layout
       }}
    end
  end

  defp ensure_node_ids(nodes) do
    case Enum.find(nodes, &(is_nil(&1.id) or &1.id == "")) do
      nil -> :ok
      bad_node -> {:error, {:missing_node_id, Map.take(bad_node, [:name, :type_id])}}
    end
  end

  defp validate_connections(node_ids, connections) do
    invalid =
      Enum.filter(connections, fn
        %Connection{source_node_id: from, target_node_id: to} ->
          missing_endpoint?(node_ids, from, to)

        %{} = conn ->
          from = Map.get(conn, :source_node_id) || Map.get(conn, "source_node_id")
          to = Map.get(conn, :target_node_id) || Map.get(conn, "target_node_id")

          missing_endpoint?(node_ids, from, to)

        _ ->
          true
      end)

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_connections, Enum.map(invalid, &summarize_conn/1)}}
    end
  end

  defp missing_endpoint?(node_ids, from, to) do
    not MapSet.member?(node_ids, from) or not MapSet.member?(node_ids, to)
  end

  defp summarize_conn(%Connection{} = conn) do
    %{
      source_node_id: conn.source_node_id,
      target_node_id: conn.target_node_id
    }
  end

  defp summarize_conn(%{} = conn) do
    %{
      source_node_id: Map.get(conn, :source_node_id) || Map.get(conn, "source_node_id"),
      target_node_id: Map.get(conn, :target_node_id) || Map.get(conn, "target_node_id")
    }
  end

  defp normalize_node(%Node{} = node) do
    %{
      id: node.id,
      name: node.name || node.type_id || "Node",
      type: classify_type(node.type_id),
      type_id: node.type_id,
      position: node.position || %{}
    }
  end

  defp normalize_node(%{} = node) do
    id = Map.get(node, :id) || Map.get(node, "id")
    type_id = Map.get(node, :type_id) || Map.get(node, "type_id")

    %{
      id: id,
      name:
        Map.get(node, :name) ||
          Map.get(node, "name") ||
          type_id ||
          "Node",
      type: classify_type(type_id),
      type_id: type_id,
      position: Map.get(node, :position) || Map.get(node, "position") || %{}
    }
  end

  defp classify_type(nil), do: :step

  defp classify_type(type_id) do
    case Nodes.get_type(type_id) do
      {:ok, %Type{node_kind: :control_flow}} -> :rule
      {:ok, %Type{node_kind: :trigger}} -> :state_machine
      {:ok, _type} -> :step
      _ -> :step
    end
  end

  defp build_layout(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {node, idx}, acc ->
      {x, y} = position_or_fallback(node.position, idx)
      Map.put(acc, node.id, {x, y, @node_width, @node_height})
    end)
  end

  defp position_or_fallback(position, idx) do
    x = coord(position, :x)
    y = coord(position, :y)

    if is_number(x) and is_number(y) do
      {x, y}
    else
      fallback_position(idx)
    end
  end

  defp coord(position, key) when is_map(position) do
    cond do
      is_number(Map.get(position, key)) -> Map.get(position, key)
      is_number(Map.get(position, Atom.to_string(key))) -> Map.get(position, Atom.to_string(key))
      true -> nil
    end
  end

  defp coord(_, _), do: nil

  defp fallback_position(idx) do
    col = rem(idx, 3)
    row = div(idx, 3)
    {80 + col * 240, 60 + row * 140}
  end

  defp normalize_edge(%Connection{} = conn) do
    %{
      id: conn.id,
      from: conn.source_node_id,
      to: conn.target_node_id
    }
  end

  defp normalize_edge(%{} = conn) do
    from = Map.get(conn, :source_node_id) || Map.get(conn, "source_node_id")
    to = Map.get(conn, :target_node_id) || Map.get(conn, "target_node_id")

    %{
      id: Map.get(conn, :id) || Map.get(conn, "id") || "#{from}-#{to}",
      from: from,
      to: to
    }
  end
end
