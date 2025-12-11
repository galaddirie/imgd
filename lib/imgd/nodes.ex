defmodule Imgd.Nodes do
  @moduledoc """
  Public API for node types.

  Node types are templates/blueprints that define what nodes users can add to workflows.
  Each type specifies configuration schemas, input/output schemas, and the executor
  module that implements the actual logic.

  ## Architecture

  - Types are defined as code in executor modules using `Imgd.Nodes.Definition`
  - The `Imgd.Nodes.Registry` loads all types at startup and provides fast lookups
  - Workflows reference types by ID (e.g., "http_request") in their node definitions

  ## Example

      # Get all available node types
      types = Imgd.Nodes.list_types()

      # Get a specific type
      {:ok, http_type} = Imgd.Nodes.get_type("http_request")

      # Group types by category for UI
      grouped = Imgd.Nodes.types_by_category()
  """

  alias Imgd.Nodes.{Registry, Type}

  @doc """
  Returns all registered node types.
  """
  @spec list_types() :: [Type.t()]
  defdelegate list_types, to: Registry, as: :all

  @doc """
  Gets a node type by ID.

  ## Examples

      {:ok, type} = Imgd.Nodes.get_type("http_request")
      {:error, :not_found} = Imgd.Nodes.get_type("nonexistent")
  """
  @spec get_type(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  defdelegate get_type(type_id), to: Registry, as: :get

  @doc """
  Gets a node type by ID or raises if not found.
  """
  @spec get_type!(String.t()) :: Type.t()
  defdelegate get_type!(type_id), to: Registry, as: :get!

  @doc """
  Checks if a node type exists.
  """
  @spec type_exists?(String.t()) :: boolean()
  defdelegate type_exists?(type_id), to: Registry, as: :exists?

  @doc """
  Returns node types grouped by category.

  Useful for building the node palette in the UI.

  ## Example

      %{
        "Integrations" => [%Type{id: "http_request", ...}],
        "Data" => [%Type{id: "transform", ...}, %Type{id: "format", ...}],
        ...
      }
  """
  @spec types_by_category() :: %{String.t() => [Type.t()]}
  defdelegate types_by_category, to: Registry, as: :grouped_by_category

  @doc """
  Returns all unique category names.
  """
  @spec categories() :: [String.t()]
  defdelegate categories, to: Registry

  @doc """
  Lists node types filtered by category.
  """
  @spec list_types_by_category(String.t()) :: [Type.t()]
  defdelegate list_types_by_category(category), to: Registry, as: :list_by_category

  @doc """
  Lists node types filtered by kind.

  ## Examples

      Imgd.Nodes.list_types_by_kind(:action)
      Imgd.Nodes.list_types_by_kind(:trigger)
      Imgd.Nodes.list_types_by_kind(:transform)
      Imgd.Nodes.list_types_by_kind(:control_flow)
  """
  @spec list_types_by_kind(Type.node_kind()) :: [Type.t()]
  defdelegate list_types_by_kind(kind), to: Registry, as: :list_by_kind

  @doc """
  Returns the count of registered node types.
  """
  @spec type_count() :: non_neg_integer()
  defdelegate type_count, to: Registry, as: :count

  @doc """
  Validates that all node type IDs in a workflow exist.

  Returns `:ok` if all types exist, or `{:error, missing_ids}` with a list
  of type IDs that were not found.
  """
  @spec validate_type_ids([String.t()]) :: :ok | {:error, [String.t()]}
  def validate_type_ids(type_ids) when is_list(type_ids) do
    missing =
      type_ids
      |> Enum.uniq()
      |> Enum.reject(&type_exists?/1)

    case missing do
      [] -> :ok
      ids -> {:error, ids}
    end
  end
end
