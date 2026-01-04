defmodule Imgd.Steps.Registry do
  @moduledoc """
  In-memory registry for step types.

  Step types are defined as code (not in DB) and loaded at startup. This provides:
  - Type-safe definitions with compile-time validation
  - Easy versioning through git
  - Fast lookups via ETS

  ## Usage

      # Get all step types
      Imgd.Steps.Registry.all()

      # Get a specific step type
      {:ok, type} = Imgd.Steps.Registry.get("http_request")

      # List by category
      Imgd.Steps.Registry.list_by_category("Integrations")

      # List by kind
      Imgd.Steps.Registry.list_by_kind(:action)

  ## Adding New Step Types

  Create an executor module that uses `Imgd.Steps.Definition`:

      defmodule Imgd.Steps.Executors.MyStep do
        use Imgd.Steps.Definition,
          id: "my_step",
          name: "My Step",
          category: "Custom",
          description: "Does something cool",
          icon: "hero-sparkles",
          kind: :action

        @behaviour Imgd.Steps.Executors.Behaviour
        # ... implementation
      end

  The step type will be automatically discovered and registered on startup.
  """

  use GenServer

  alias Imgd.Steps.Type

  require Logger

  @ets_table :imgd_step_types

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all registered step types.
  """
  @spec all() :: [Type.t()]
  def all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, type} -> type end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets a step type by ID.
  """
  @spec get(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  def get(type_id) when is_binary(type_id) do
    case :ets.lookup(@ets_table, type_id) do
      [{^type_id, type}] -> {:ok, type}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets a step type by ID or raises.
  """
  @spec get!(String.t()) :: Type.t()
  def get!(type_id) do
    case get(type_id) do
      {:ok, type} -> type
      {:error, :not_found} -> raise "Step type not found: #{type_id}"
    end
  end

  @doc """
  Checks if a step type exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(type_id) when is_binary(type_id) do
    :ets.member(@ets_table, type_id)
  end

  @doc """
  Lists step types by category.
  """
  @spec list_by_category(String.t()) :: [Type.t()]
  def list_by_category(category) when is_binary(category) do
    all()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Lists step types by kind.
  """
  @spec list_by_kind(Type.step_kind()) :: [Type.t()]
  def list_by_kind(kind) when kind in [:action, :trigger, :control_flow, :transform] do
    all()
    |> Enum.filter(&(&1.step_kind == kind))
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
  Returns step types grouped by category.
  """
  @spec grouped_by_category() :: %{String.t() => [Type.t()]}
  def grouped_by_category do
    all()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns the count of registered step types.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@ets_table, :size)
  end

  @doc """
  Returns step types formatted for the node library UI.
  """
  @spec library_items() :: [map()]
  def library_items do
    all()
    |> Enum.map(&library_item_from_type/1)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    # Load all built-in step types
    types = discover_step_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Step Registry initialized with #{length(types)} step types")

    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Clear and reload all types
    :ets.delete_all_objects(@ets_table)

    types = discover_step_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Step Registry reloaded with #{length(types)} step types")

    {:reply, :ok, state}
  end

  # ============================================================================
  # Step Type Discovery
  # ============================================================================

  defp discover_step_types do
    # Get all executor modules and load their definitions
    builtin_executor_modules()
    |> Enum.filter(&has_step_definition?/1)
    |> Enum.map(& &1.__step_definition__())
    |> validate_unique_ids()
  end

  defp library_item_from_type(%Type{} = type) do
    %{
      type_id: type.id,
      name: type.name,
      description: type.description,
      icon: type.icon,
      category: type.category,
      step_kind: Atom.to_string(type.step_kind)
    }
  end

  # Explicit list of builtin executor modules.
  # This ensures they are loaded before the registry tries to discover them.
  # Add new executor modules here as they are created.
  defp builtin_executor_modules do
    [
      Imgd.Steps.Executors.ManualInput,
      Imgd.Steps.Executors.HttpRequest,
      Imgd.Steps.Executors.JsonParser,
      Imgd.Steps.Executors.DataFilter,
      Imgd.Steps.Executors.DataTransform,
      Imgd.Steps.Executors.DataOutput,
      Imgd.Steps.Executors.Condition,
      Imgd.Steps.Executors.Switch,
      Imgd.Steps.Executors.Format,
      Imgd.Steps.Executors.Debug,
      Imgd.Steps.Executors.Math,
      Imgd.Steps.Executors.Aggregator,
      Imgd.Steps.Executors.Splitter
    ]
  end

  defp has_step_definition?(module) do
    # Ensure module is loaded
    Code.ensure_loaded(module)
    function_exported?(module, :__step_definition__, 0)
  end

  defp validate_unique_ids(types) do
    ids = Enum.map(types, & &1.id)
    unique_ids = Enum.uniq(ids)

    if length(ids) != length(unique_ids) do
      duplicates = ids -- unique_ids

      raise "Duplicate step type IDs found: #{inspect(duplicates)}"
    end

    types
  end
end
