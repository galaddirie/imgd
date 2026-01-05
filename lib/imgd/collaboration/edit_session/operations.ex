defmodule Imgd.Collaboration.EditSession.Operations do
  @moduledoc """
  Pure functions for validating and applying edit operations to workflow drafts.
  """

  alias Imgd.Workflows.WorkflowDraft
  alias Imgd.Workflows.Embeds.{Step, Connection}
  alias Imgd.Collaboration.EditOperation
  alias Imgd.Graph
  require Logger

  @doc """
  Normalizes an operation payload by ensuring keys are atoms or strings consistently.
  """
  def normalize_payload(nil), do: %{}

  def normalize_payload(payload) when is_map(payload) do
    # For now we just return as is, but helpers like `field/2` will handle it.
    payload
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

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
      :add_step ->
        validate_add_step(draft, operation.payload)

      :remove_step ->
        validate_remove_step(draft, operation.payload)

      :update_step_config ->
        validate_update_step(draft, operation.payload)

      :update_step_position ->
        validate_update_step(draft, operation.payload)

      :update_step_metadata ->
        validate_update_step(draft, operation.payload)

      :add_connection ->
        validate_add_connection(draft, operation.payload)

      :remove_connection ->
        validate_remove_connection(draft, operation.payload)

      # Editor operations don't need draft validation
      type when type in [:pin_step_output, :unpin_step_output, :disable_step, :enable_step] ->
        :ok

      _ ->
        {:error, :unknown_operation_type}
    end
  end

  @doc "Apply an operation to a draft, returning updated draft."
  @spec apply(WorkflowDraft.t(), operation() | map()) ::
          {:ok, WorkflowDraft.t()} | {:error, term()}
  def apply(draft, operation) do
    type = field(operation, :type)
    payload = field(operation, :payload)
    Logger.info("Operations.apply: type=#{inspect(type)} payload=#{inspect(payload)}")

    case do_apply(draft, type, payload) do
      {:ok, updated_draft} = result ->
        if draft == updated_draft do
          Logger.warning("Operations.apply: No changes made to draft for type=#{inspect(type)}")
        end

        result

      {:error, reason} = error ->
        Logger.error("Operations.apply FAILED: type=#{inspect(type)} reason=#{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # Validation Functions
  # ============================================================================

  defp validate_add_step(draft, payload) do
    step_data = field(payload, :step)
    step_id = field(step_data, :id)

    cond do
      step_exists?(draft, step_id) ->
        {:error, {:step_already_exists, step_id}}

      not valid_step_type?(step_data) ->
        {:error, :invalid_step_type}

      true ->
        :ok
    end
  end

  defp validate_remove_step(draft, payload) do
    step_id = field(payload, :step_id)

    if step_exists?(draft, step_id) do
      :ok
    else
      {:error, {:step_not_found, step_id}}
    end
  end

  defp validate_update_step(draft, payload) do
    step_id = field(payload, :step_id)

    if step_exists?(draft, step_id) do
      :ok
    else
      {:error, {:step_not_found, step_id}}
    end
  end

  defp validate_add_connection(draft, payload) do
    conn_data = field(payload, :connection)
    source_id = field(conn_data, :source_step_id)
    target_id = field(conn_data, :target_step_id)
    conn_id = field(conn_data, :id)

    cond do
      connection_exists?(draft, conn_id) ->
        {:error, {:connection_already_exists, conn_id}}

      not step_exists?(draft, source_id) ->
        {:error, {:source_step_not_found, source_id}}

      not step_exists?(draft, target_id) ->
        {:error, {:target_step_not_found, target_id}}

      source_id == target_id ->
        {:error, :self_loop_not_allowed}

      would_create_cycle?(draft, source_id, target_id) ->
        {:error, :would_create_cycle}

      true ->
        :ok
    end
  end

  defp validate_remove_connection(draft, payload) do
    conn_id = field(payload, :connection_id)

    if connection_exists?(draft, conn_id) do
      :ok
    else
      {:error, {:connection_not_found, conn_id}}
    end
  end

  # ============================================================================
  # Apply Functions
  # ============================================================================

  defp do_apply(draft, :add_step, payload) do
    step_data = field(payload, :step)
    step = build_step(step_data)
    new_steps = draft.steps ++ [step]
    {:ok, %{draft | steps: new_steps}}
  end

  defp do_apply(draft, :remove_step, payload) do
    step_id = field(payload, :step_id)
    Logger.info("Operations.do_apply(:remove_step): step_id=#{inspect(step_id)}")

    # Remove step and all its connections
    new_steps =
      Enum.reject(draft.steps, fn step ->
        id = field(step, :id)
        match = id == step_id
        if match, do: Logger.info("Operations.do_apply: Found step to remove: #{id}")
        match
      end)

    new_connections =
      Enum.reject(draft.connections, fn conn ->
        source_id = field(conn, :source_step_id)
        target_id = field(conn, :target_step_id)
        match = source_id == step_id or target_id == step_id

        if match,
          do:
            Logger.info(
              "Operations.do_apply: Removing connection #{field(conn, :id)} because it links to removed step #{step_id}"
            )

        match
      end)

    {:ok, %{draft | steps: new_steps, connections: new_connections}}
  end

  defp do_apply(draft, :update_step_config, payload) do
    step_id = field(payload, :step_id)
    patch = field(payload, :patch)

    update_step(draft, step_id, fn step ->
      new_config = apply_json_patch(step.config, patch)
      %{step | config: new_config}
    end)
  end

  defp do_apply(draft, :update_step_position, payload) do
    step_id = field(payload, :step_id)
    position = field(payload, :position)

    update_step(draft, step_id, fn step ->
      %{step | position: position}
    end)
  end

  defp do_apply(draft, :update_step_metadata, payload) do
    step_id = field(payload, :step_id)
    changes = field(payload, :changes)

    update_step(draft, step_id, fn step ->
      step
      |> maybe_update(:name, changes)
      |> maybe_update(:notes, changes)
      |> maybe_update(:config, changes)
    end)
  end

  defp do_apply(draft, :add_connection, payload) do
    conn_data = field(payload, :connection)
    connection = build_connection(conn_data)
    new_connections = draft.connections ++ [connection]
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(draft, :remove_connection, payload) do
    conn_id = field(payload, :connection_id)
    new_connections = Enum.reject(draft.connections, &(field(&1, :id) == conn_id))
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(_draft, type, _payload) do
    {:error, {:unhandled_operation, type}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp step_exists?(draft, step_id) do
    Enum.any?(draft.steps, fn step -> field(step, :id) == step_id end)
  end

  defp connection_exists?(draft, conn_id) do
    Enum.any?(draft.connections, fn conn -> field(conn, :id) == conn_id end)
  end

  defp valid_step_type?(step_data) do
    type_id = field(step_data, :type_id)
    Imgd.Steps.Registry.exists?(type_id)
  end

  defp would_create_cycle?(draft, source_id, target_id) do
    # Build graph with proposed edge and check for cycles
    case Graph.from_workflow(draft.steps, draft.connections) do
      {:ok, graph} ->
        # Add the proposed edge
        test_graph = Graph.add_edge(graph, source_id, target_id)
        # Check if target can reach source (would indicate cycle)
        target_id in Graph.upstream(test_graph, source_id)

      {:error, _} ->
        false
    end
  end

  defp update_step(draft, step_id, update_fn) do
    new_steps =
      Enum.map(draft.steps, fn step ->
        if field(step, :id) == step_id do
          case update_fn.(step) do
            {:ok, updated} -> updated
            %Step{} = updated -> updated
            updated when is_map(updated) -> updated
          end
        else
          step
        end
      end)

    {:ok, %{draft | steps: new_steps}}
  end

  defp build_step(data) when is_map(data) do
    %Step{
      id: field(data, :id),
      type_id: field(data, :type_id),
      name: field(data, :name),
      config: field(data, :config) || %{},
      position: field(data, :position) || %{x: 0, y: 0},
      notes: field(data, :notes)
    }
  end

  defp build_connection(data) when is_map(data) do
    %Connection{
      id: field(data, :id),
      source_step_id: field(data, :source_step_id),
      source_output: field(data, :source_output) || "main",
      target_step_id: field(data, :target_step_id),
      target_input: field(data, :target_input) || "main"
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
