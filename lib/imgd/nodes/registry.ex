defmodule Imgd.Nodes.Registry do
  @moduledoc """
  In-memory registry for node types.

  Node types are defined as code (not in DB) and loaded at startup. This provides:
  - Type-safe definitions with compile-time validation
  - Easy versioning through git
  - Fast lookups via ETS

  ## Usage

      # Get all node types
      Imgd.Nodes.Registry.all()

      # Get a specific node type
      {:ok, type} = Imgd.Nodes.Registry.get("http_request")

      # List by category
      Imgd.Nodes.Registry.list_by_category("Integrations")

      # List by kind
      Imgd.Nodes.Registry.list_by_kind(:action)

  ## Adding New Node Types

  Create an executor module that uses `Imgd.Nodes.Definition`:

      defmodule Imgd.Nodes.Executors.MyNode do
        use Imgd.Nodes.Definition,
          id: "my_node",
          name: "My Node",
          category: "Custom",
          description: "Does something cool",
          icon: "hero-sparkles",
          kind: :action

        @behaviour Imgd.Runtime.NodeExecutor
        # ... implementation
      end

  The node type will be automatically discovered and registered on startup.
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

  @doc """
  Returns all registered node types.
  """
  @spec all() :: [Type.t()]
  def all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, type} -> type end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets a node type by ID.
  """
  @spec get(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  def get(type_id) when is_binary(type_id) do
    case :ets.lookup(@ets_table, type_id) do
      [{^type_id, type}] -> {:ok, type}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets a node type by ID or raises.
  """
  @spec get!(String.t()) :: Type.t()
  def get!(type_id) do
    case get(type_id) do
      {:ok, type} -> type
      {:error, :not_found} -> raise "Node type not found: #{type_id}"
    end
  end

  @doc """
  Checks if a node type exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(type_id) when is_binary(type_id) do
    :ets.member(@ets_table, type_id)
  end

  @doc """
  Lists node types by category.
  """
  @spec list_by_category(String.t()) :: [Type.t()]
  def list_by_category(category) when is_binary(category) do
    all()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Lists node types by kind.
  """
  @spec list_by_kind(Type.node_kind()) :: [Type.t()]
  def list_by_kind(kind) when kind in [:action, :trigger, :control_flow, :transform] do
    all()
    |> Enum.filter(&(&1.node_kind == kind))
  end

  @doc """
  Returns all unique categories.
  """
  @spec categories() :: [String.t()]
  def categories do
    all()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns node types grouped by category.
  """
  @spec grouped_by_category() :: %{String.t() => [Type.t()]}
  def grouped_by_category do
    all()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns the count of registered node types.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@ets_table, :size)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    # Load all built-in node types
    types = discover_node_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Node Registry initialized with #{length(types)} node types")

    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Clear and reload all types
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
    # Get all executor modules and load their definitions
    builtin_executor_modules()
    |> Enum.filter(&has_node_definition?/1)
    |> Enum.map(& &1.__node_definition__())
    |> validate_unique_ids()
  end

  # Explicit list of builtin executor modules.
  # This ensures they are loaded before the registry tries to discover them.
  # Add new executor modules here as they are created.
  defp builtin_executor_modules do
    [
      Imgd.Nodes.Executors.HttpRequest,
      Imgd.Nodes.Executors.Transform,
      Imgd.Nodes.Executors.Format,
      Imgd.Nodes.Executors.Debug,
      Imgd.Nodes.Executors.Math,
      Imgd.Nodes.Executors.Wait
    ]
  end

  defp has_node_definition?(module) do
    # Ensure module is loaded
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
