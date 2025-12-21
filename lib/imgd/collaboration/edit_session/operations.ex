defmodule Imgd.Collaboration.EditSession.Operations do
  @moduledoc """
  Pure functions for validating and applying edit operations to workflow drafts.
  """

  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Node, Connection}
  alias Imgd.Graph

  @type operation :: %{
          type: atom(),
          payload: map(),
          id: String.t(),
          user_id: String.t()
        }

  @doc "Validate an operation against current draft state."
  @spec validate(WorkflowDraft.t(), operation()) :: :ok | {:error, term()}
  def validate(draft, operation) do
    case operation.type do
      :add_node ->
        validate_add_node(draft, operation.payload)

      :remove_node ->
        validate_remove_node(draft, operation.payload)

      :update_node_config ->
        validate_update_node(draft, operation.payload)

      :update_node_position ->
        validate_update_node(draft, operation.payload)

      :update_node_metadata ->
        validate_update_node(draft, operation.payload)

      :add_connection ->
        validate_add_connection(draft, operation.payload)

      :remove_connection ->
        validate_remove_connection(draft, operation.payload)

      # Editor operations don't need draft validation
      type when type in [:pin_node_output, :unpin_node_output, :disable_node, :enable_node] ->
        :ok

      _ ->
        {:error, :unknown_operation_type}
    end
  end

  @doc "Apply an operation to a draft, returning updated draft."
  @spec apply(WorkflowDraft.t(), operation() | map()) ::
          {:ok, WorkflowDraft.t()} | {:error, term()}
  def apply(draft, operation) do
    # Handle both operation structs and maps
    type = Map.get(operation, :type) || Map.get(operation, "type")
    payload = Map.get(operation, :payload) || Map.get(operation, "payload")

    do_apply(draft, type, payload)
  end

  # ============================================================================
  # Validation Functions
  # ============================================================================

  defp validate_add_node(draft, %{node: node_data}) do
    node_id = node_data.id || node_data["id"]

    cond do
      node_exists?(draft, node_id) ->
        {:error, {:node_already_exists, node_id}}

      not valid_node_type?(node_data) ->
        {:error, :invalid_node_type}

      true ->
        :ok
    end
  end

  defp validate_remove_node(draft, %{node_id: node_id}) do
    if node_exists?(draft, node_id) do
      :ok
    else
      {:error, {:node_not_found, node_id}}
    end
  end

  defp validate_update_node(draft, %{node_id: node_id}) do
    if node_exists?(draft, node_id) do
      :ok
    else
      {:error, {:node_not_found, node_id}}
    end
  end

  defp validate_add_connection(draft, %{connection: conn_data}) do
    source_id = conn_data.source_node_id || conn_data["source_node_id"]
    target_id = conn_data.target_node_id || conn_data["target_node_id"]
    conn_id = conn_data.id || conn_data["id"]

    cond do
      connection_exists?(draft, conn_id) ->
        {:error, {:connection_already_exists, conn_id}}

      not node_exists?(draft, source_id) ->
        {:error, {:source_node_not_found, source_id}}

      not node_exists?(draft, target_id) ->
        {:error, {:target_node_not_found, target_id}}

      source_id == target_id ->
        {:error, :self_loop_not_allowed}

      would_create_cycle?(draft, source_id, target_id) ->
        {:error, :would_create_cycle}

      true ->
        :ok
    end
  end

  defp validate_remove_connection(draft, %{connection_id: conn_id}) do
    if connection_exists?(draft, conn_id) do
      :ok
    else
      {:error, {:connection_not_found, conn_id}}
    end
  end

  # ============================================================================
  # Apply Functions
  # ============================================================================

  defp do_apply(draft, :add_node, %{node: node_data}) do
    node = build_node(node_data)
    new_nodes = draft.nodes ++ [node]
    {:ok, %{draft | nodes: new_nodes}}
  end

  defp do_apply(draft, :remove_node, %{node_id: node_id}) do
    # Remove node and all its connections
    new_nodes = Enum.reject(draft.nodes, &(&1.id == node_id))

    new_connections =
      Enum.reject(draft.connections, fn conn ->
        conn.source_node_id == node_id or conn.target_node_id == node_id
      end)

    {:ok, %{draft | nodes: new_nodes, connections: new_connections}}
  end

  defp do_apply(draft, :update_node_config, %{node_id: node_id, patch: patch}) do
    update_node(draft, node_id, fn node ->
      new_config = apply_json_patch(node.config, patch)
      %{node | config: new_config}
    end)
  end

  defp do_apply(draft, :update_node_position, %{node_id: node_id, position: position}) do
    update_node(draft, node_id, fn node ->
      %{node | position: position}
    end)
  end

  defp do_apply(draft, :update_node_metadata, %{node_id: node_id, changes: changes}) do
    update_node(draft, node_id, fn node ->
      node
      |> maybe_update(:name, changes)
      |> maybe_update(:notes, changes)
    end)
  end

  defp do_apply(draft, :add_connection, %{connection: conn_data}) do
    connection = build_connection(conn_data)
    new_connections = draft.connections ++ [connection]
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(draft, :remove_connection, %{connection_id: conn_id}) do
    new_connections = Enum.reject(draft.connections, &(&1.id == conn_id))
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(_draft, type, _payload) do
    {:error, {:unhandled_operation, type}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp node_exists?(draft, node_id) do
    Enum.any?(draft.nodes, &(&1.id == node_id))
  end

  defp connection_exists?(draft, conn_id) do
    Enum.any?(draft.connections, &(&1.id == conn_id))
  end

  defp valid_node_type?(node_data) do
    type_id = node_data.type_id || node_data["type_id"]
    Imgd.Nodes.Registry.exists?(type_id)
  end

  defp would_create_cycle?(draft, source_id, target_id) do
    # Build graph with proposed edge and check for cycles
    case Graph.from_workflow(draft.nodes, draft.connections) do
      {:ok, graph} ->
        # Add the proposed edge
        test_graph = Graph.add_edge(graph, source_id, target_id)
        # Check if target can reach source (would indicate cycle)
        target_id in Graph.upstream(test_graph, source_id)

      {:error, _} ->
        false
    end
  end

  defp update_node(draft, node_id, update_fn) do
    new_nodes =
      Enum.map(draft.nodes, fn node ->
        if node.id == node_id do
          update_fn.(node)
        else
          node
        end
      end)

    {:ok, %{draft | nodes: new_nodes}}
  end

  defp build_node(data) when is_map(data) do
    %Node{
      id: data[:id] || data["id"],
      type_id: data[:type_id] || data["type_id"],
      name: data[:name] || data["name"],
      config: data[:config] || data["config"] || %{},
      position: data[:position] || data["position"] || %{x: 0, y: 0},
      notes: data[:notes] || data["notes"]
    }
  end

  defp build_connection(data) when is_map(data) do
    %Connection{
      id: data[:id] || data["id"],
      source_node_id: data[:source_node_id] || data["source_node_id"],
      source_output: data[:source_output] || data["source_output"] || "main",
      target_node_id: data[:target_node_id] || data["target_node_id"],
      target_input: data[:target_input] || data["target_input"] || "main"
    }
  end

  @doc false
  def apply_json_patch(config, patches) when is_list(patches) do
    Enum.reduce(patches, config, &apply_single_patch/2)
  end

  defp apply_single_patch(%{"op" => "replace", "path" => path, "value" => value}, config) do
    put_at_path(config, parse_path(path), value)
  end

  defp apply_single_patch(%{"op" => "add", "path" => path, "value" => value}, config) do
    put_at_path(config, parse_path(path), value)
  end

  defp apply_single_patch(%{"op" => "remove", "path" => path}, config) do
    remove_at_path(config, parse_path(path))
  end

  defp apply_single_patch(_, config), do: config

  defp parse_path("/" <> path), do: String.split(path, "/", trim: true)
  defp parse_path(path), do: String.split(path, "/", trim: true)

  defp put_at_path(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_at_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_at_path(nested, rest, value))
  end

  defp remove_at_path(map, [key]) do
    Map.delete(map, key)
  end

  defp remove_at_path(map, [key | rest]) do
    case Map.get(map, key) do
      nested when is_map(nested) ->
        Map.put(map, key, remove_at_path(nested, rest))

      _ ->
        map
    end
  end

  defp maybe_update(struct, field, changes) do
    case Map.get(changes, field) || Map.get(changes, to_string(field)) do
      nil -> struct
      value -> Map.put(struct, field, value)
    end
  end
end
