defmodule Imgd.Nodes.Registry do
  @moduledoc """
  In-memory registry for node types.

  Node types are defined as code (not in DB) and loaded at startup. This provides:
  - Type-safe definitions with compile-time validation
  - Easy versioning through git
  - Fast lookups via ETS

  ## Control Flow Nodes

  The registry includes control flow nodes for branching and collection processing:
  - `branch` - If/else conditional routing
  - `switch` - Multi-way value-based routing
  - `merge` - Combine branches with join semantics
  - `split_items` - Fan-out array to items
  - `aggregate_items` - Fan-in items to single result

  ## Usage

      # Get all node types
      Imgd.Nodes.Registry.all()

      # Get control flow nodes
      Imgd.Nodes.Registry.list_by_kind(:control_flow)

      # Get a specific node type
      {:ok, type} = Imgd.Nodes.Registry.get("branch")
  """

  use GenServer

  alias Imgd.Nodes.Type

  require Logger

  @ets_table :imgd_node_types

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec all() :: [Type.t()]
  def all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, type} -> type end)
    |> Enum.sort_by(& &1.name)
  end

  @spec get(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  def get(type_id) when is_binary(type_id) do
    case :ets.lookup(@ets_table, type_id) do
      [{^type_id, type}] -> {:ok, type}
      [] -> {:error, :not_found}
    end
  end

  @spec get!(String.t()) :: Type.t()
  def get!(type_id) do
    case get(type_id) do
      {:ok, type} -> type
      {:error, :not_found} -> raise "Node type not found: #{type_id}"
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(type_id) when is_binary(type_id) do
    :ets.member(@ets_table, type_id)
  end

  @spec list_by_category(String.t()) :: [Type.t()]
  def list_by_category(category) when is_binary(category) do
    all()
    |> Enum.filter(&(&1.category == category))
  end

  @spec list_by_kind(Type.node_kind()) :: [Type.t()]
  def list_by_kind(kind) when kind in [:action, :trigger, :control_flow, :transform] do
    all()
    |> Enum.filter(&(&1.node_kind == kind))
  end

  @spec categories() :: [String.t()]
  def categories do
    all()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec grouped_by_category() :: %{String.t() => [Type.t()]}
  def grouped_by_category do
    all()
    |> Enum.group_by(& &1.category)
  end

  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@ets_table, :size)
  end

  @doc """
  Returns true if the node type has join semantics (like Merge).
  """
  @spec has_join_semantics?(String.t()) :: boolean()
  def has_join_semantics?(type_id) do
    case get(type_id) do
      {:ok, type} ->
        type.id in ["merge"]

      _ ->
        false
    end
  end

  @doc """
  Returns true if the node type produces routed outputs (like Branch, Switch).
  """
  @spec has_routed_outputs?(String.t()) :: boolean()
  def has_routed_outputs?(type_id) do
    case get(type_id) do
      {:ok, type} ->
        type.id in ["branch", "switch"]

      _ ->
        false
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    types = discover_node_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Node Registry initialized with #{length(types)} node types")

    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@ets_table)

    types = discover_node_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Node Registry reloaded with #{length(types)} node types")

    {:reply, :ok, state}
  end

  # ============================================================================
  # Node Type Discovery
  # ============================================================================

  defp discover_node_types do
    builtin_executor_modules()
    |> Enum.filter(&has_node_definition?/1)
    |> Enum.map(& &1.__node_definition__())
    |> validate_unique_ids()
  end

  # Explicit list of builtin executor modules.
  # Add new executor modules here as they are created.
  defp builtin_executor_modules do
    [
      # Actions
      Imgd.Nodes.Executors.Debug,

      # Transforms
      Imgd.Nodes.Executors.Transform,
      Imgd.Nodes.Executors.Format,
      Imgd.Nodes.Executors.Math,

      # Control Flow
      Imgd.Nodes.Executors.Branch,
      Imgd.Nodes.Executors.Switch,
      Imgd.Nodes.Executors.Merge,

      # Collection Processing
      Imgd.Nodes.Executors.SplitItems,
      Imgd.Nodes.Executors.AggregateItems
    ]
  end

  defp has_node_definition?(module) do
    Code.ensure_loaded(module)
    function_exported?(module, :__node_definition__, 0)
  end

  defp validate_unique_ids(types) do
    ids = Enum.map(types, & &1.id)
    unique_ids = Enum.uniq(ids)

    if length(ids) != length(unique_ids) do
      duplicates = ids -- unique_ids
      raise "Duplicate node type IDs found: #{inspect(duplicates)}"
    end

    types
  end
end
