defmodule Imgd.Workflows.GraphExtractor do
  @moduledoc """
  Extracts visualization data from Runic workflow graphs.

  Transforms the internal Runic graph representation into a simplified
  structure suitable for rendering in the UI.
  """

  alias Imgd.Workflows.Workflow

  @type workflow_node :: %{
          id: integer(),
          name: String.t(),
          type: :step | :rule | :accumulator | :state_machine | :map | :reduce,
          hash: integer()
        }

  @type edge :: %{
          from: integer(),
          to: integer(),
          label: atom()
        }

  @type graph_data :: %{
          nodes: [workflow_node()],
          edges: [edge()],
          layout: %{integer() => {number(), number()}}
        }

  @doc """
  Extracts graph visualization data from a workflow definition.

  Returns a map with nodes, edges, and computed layout positions.
  """
  @spec extract(%Workflow{}) :: {:ok, graph_data()} | {:error, term()}
  def extract(%Workflow{definition: nil}), do: {:error, :no_definition}

  def extract(%Workflow{definition: definition}) do
    try do
      runic_workflow = rebuild_workflow(definition)
      graph_data = extract_from_runic(runic_workflow)
      {:ok, graph_data}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Extracts graph data directly from a Runic.Workflow struct.
  """
  @spec extract_from_runic(Runic.Workflow.t()) :: graph_data()
  def extract_from_runic(runic_workflow) do
    graph = runic_workflow.graph

    rule_internal_names = rule_internal_names(runic_workflow)

    # Extract nodes (steps, rules, etc. - not facts)
    nodes =
      graph
      |> extract_nodes(rule_internal_names)
      |> merge_rule_nodes(runic_workflow)

    # Extract edges between nodes
    edges =
      graph
      |> extract_edges(nodes)
      |> add_linear_edges(runic_workflow, nodes)
      |> add_rule_edges(runic_workflow, nodes)

    # Compute layout positions
    layout = compute_layout(nodes, edges)

    %{
      nodes: nodes,
      edges: edges,
      layout: layout
    }
  end

  # Extract only the "runnable" nodes (steps, rules, etc.)
  defp extract_nodes(graph, ignore_names) do
    graph
    |> Graph.vertices()
    |> Enum.filter(&is_runnable_node?/1)
    |> Enum.map(&node_to_map/1)
    |> Enum.reject(&MapSet.member?(ignore_names, &1.name))
  end

  defp is_runnable_node?(%Runic.Workflow.Step{}), do: true
  defp is_runnable_node?(%Runic.Workflow.Rule{}), do: true
  defp is_runnable_node?(%Runic.Workflow.Accumulator{}), do: true
  defp is_runnable_node?(%Runic.Workflow.StateMachine{}), do: true
  defp is_runnable_node?(_), do: false

  defp node_to_map(node) do
    %{
      id: node.hash,
      name: node_name(node),
      type: node_type(node),
      hash: node.hash
    }
  end

  defp node_name(%{name: name}) when not is_nil(name), do: to_string(name)
  defp node_name(%{hash: hash}), do: "step_#{hash}"

  defp node_type(%Runic.Workflow.Step{}), do: :step
  defp node_type(%Runic.Workflow.Rule{}), do: :rule
  defp node_type(%Runic.Workflow.Accumulator{}), do: :accumulator
  defp node_type(%Runic.Workflow.StateMachine{}), do: :state_machine
  defp node_type(_), do: :unknown

  # Extract edges between runnable nodes
  # We need to trace through facts to find node-to-node connections
  defp extract_edges(graph, nodes) do
    node_hashes = MapSet.new(nodes, & &1.id)

    # Get all edges and find paths between nodes through facts
    graph
    |> Graph.edges()
    |> Enum.flat_map(fn edge ->
      find_node_connections(graph, edge, node_hashes)
    end)
    |> Enum.uniq()
  end

  # Trace connections between nodes through fact vertices
  defp find_node_connections(graph, edge, node_hashes) do
    from_hash = vertex_hash(edge.v1)
    to_hash = vertex_hash(edge.v2)

    cond do
      # Direct node-to-node edge
      MapSet.member?(node_hashes, from_hash) and MapSet.member?(node_hashes, to_hash) ->
        [%{from: from_hash, to: to_hash, label: edge.label}]

      # Node produces a fact - find what consumes that fact
      MapSet.member?(node_hashes, from_hash) and is_fact?(edge.v2) ->
        graph
        |> Graph.out_edges(edge.v2)
        |> Enum.filter(fn e -> MapSet.member?(node_hashes, vertex_hash(e.v2)) end)
        |> Enum.map(fn e ->
          %{from: from_hash, to: vertex_hash(e.v2), label: :flows_to}
        end)

      # Fact consumed by node - already covered by the above case
      true ->
        []
    end
  end

  defp vertex_hash(%{hash: hash}), do: hash
  defp vertex_hash(_), do: nil

  defp is_fact?(%Runic.Workflow.Fact{}), do: true
  defp is_fact?(_), do: false

  # Simple layered layout algorithm
  # Places nodes in columns based on their dependency depth
  defp compute_layout(nodes, edges) do
    if Enum.empty?(nodes) do
      %{}
    else
      # Build adjacency map
      adjacency = build_adjacency_map(edges)

      # Find root nodes (no incoming edges)
      all_ids = MapSet.new(nodes, & &1.id)
      targets = edges |> Enum.map(& &1.to) |> MapSet.new()
      roots = MapSet.difference(all_ids, targets) |> MapSet.to_list()

      # If no roots found, pick the first node
      roots = if Enum.empty?(roots), do: [hd(nodes).id], else: roots

      # Compute depths using BFS
      depths = compute_depths(roots, adjacency, %{})

      # Assign any unvisited nodes to depth 0
      depths =
        Enum.reduce(nodes, depths, fn node, acc ->
          Map.put_new(acc, node.id, 0)
        end)

      # Group nodes by depth
      nodes_by_depth =
        nodes
        |> Enum.group_by(fn node -> Map.get(depths, node.id, 0) end)

      # Compute positions
      node_width = 160
      node_height = 60
      h_spacing = 280
      v_spacing = 100

      Enum.reduce(nodes_by_depth, %{}, fn {depth, depth_nodes}, acc ->
        x = 50 + depth * h_spacing

        depth_nodes
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {node, idx}, inner_acc ->
          y = 50 + idx * v_spacing
          Map.put(inner_acc, node.id, {x, y, node_width, node_height})
        end)
      end)
    end
  end

  defp build_adjacency_map(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from, [edge.to], fn existing -> [edge.to | existing] end)
    end)
  end

  defp compute_depths([], _adjacency, depths), do: depths

  defp compute_depths([node_id | rest], adjacency, depths) do
    current_depth = Map.get(depths, node_id, 0)
    children = Map.get(adjacency, node_id, [])

    {new_depths, new_queue} =
      Enum.reduce(children, {depths, rest}, fn child_id, {d_acc, q_acc} ->
        new_depth = current_depth + 1

        if Map.get(d_acc, child_id, -1) < new_depth do
          {Map.put(d_acc, child_id, new_depth), q_acc ++ [child_id]}
        else
          {d_acc, q_acc}
        end
      end)

    compute_depths(new_queue, adjacency, new_depths)
  end

  defp merge_rule_nodes(nodes, %Runic.Workflow{} = workflow) do
    rule_nodes =
      workflow.components
      |> Enum.filter(fn {_name, component} -> match?(%Runic.Workflow.Rule{}, component) end)
      |> Enum.map(fn {name, rule} ->
        hash = rule_hash(rule)

        %{
          id: hash,
          name: to_string(name || hash),
          type: :rule,
          hash: hash
        }
      end)

    existing_ids = MapSet.new(nodes, & &1.id)
    nodes ++ Enum.reject(rule_nodes, &MapSet.member?(existing_ids, &1.id))
  end

  defp rule_internal_names(%Runic.Workflow{} = workflow) do
    workflow.components
    |> Enum.flat_map(fn
      {_name, %Runic.Workflow.Rule{workflow: %{components: components}}} ->
        components
        |> Map.keys()
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp rule_hash(%Runic.Workflow.Rule{} = rule) do
    Runic.Workflow.Components.fact_hash(rule.source)
  end

  defp add_linear_edges(edges, %Runic.Workflow{} = workflow, nodes) do
    node_ids = MapSet.new(nodes, & &1.id)

    linear_edges =
      workflow
      |> Runic.Workflow.build_log()
      |> Enum.filter(fn
        %Runic.Workflow.ComponentAdded{name: name, to: nil} ->
          name && match?(%Runic.Workflow.Step{}, Map.get(workflow.components, name))

        _ ->
          false
      end)
      |> Enum.map(& &1.name)
      |> Enum.map(&Map.get(workflow.components, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        %{from: from.hash, to: to.hash, label: :flow}
      end)
      |> Enum.filter(fn %{from: from, to: to} ->
        MapSet.member?(node_ids, from) and MapSet.member?(node_ids, to)
      end)

    (edges ++ linear_edges) |> Enum.uniq()
  end

  defp add_rule_edges(edges, %Runic.Workflow{} = workflow, nodes) do
    node_ids = MapSet.new(nodes, & &1.id)

    last_root_step =
      workflow
      |> Runic.Workflow.build_log()
      |> Enum.filter(fn
        %Runic.Workflow.ComponentAdded{name: name, to: nil} ->
          name && match?(%Runic.Workflow.Step{}, Map.get(workflow.components, name))

        _ ->
          false
      end)
      |> List.last()
      |> then(fn
        nil -> nil
        %Runic.Workflow.ComponentAdded{name: name} -> Map.get(workflow.components, name)
      end)

    rule_edges =
      if last_root_step do
        workflow.components
        |> Enum.filter(fn {_name, component} -> match?(%Runic.Workflow.Rule{}, component) end)
        |> Enum.map(fn {_name, rule} ->
          %{from: last_root_step.hash, to: rule_hash(rule), label: :flow}
        end)
        |> Enum.filter(fn %{from: from, to: to} ->
          MapSet.member?(node_ids, from) and MapSet.member?(node_ids, to)
        end)
      else
        []
      end

    (edges ++ rule_edges) |> Enum.uniq()
  end

  defp rebuild_workflow(definition) do
    events = Workflow.deserialize_definition(definition)
    Runic.Workflow.from_log(events)
  end
end
