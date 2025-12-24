defmodule Imgd.Compute.Target do
  @moduledoc """
  Represents a target for execution.

  Defines where a unit of work (step, task, function) should be executed.
  """

  @type type :: :local | :node | :flame
  @type id :: String.t() | nil

  @derive Jason.Encoder
  defstruct [
    :type,
    :id,
    :config
  ]

  @type t :: %__MODULE__{
          type: type(),
          id: id(),
          config: map()
        }

  @doc """
  Creates a new local target (default).
  """
  def local, do: %__MODULE__{type: :local, config: %{}}

  @doc """
  Creates a new node target.
  """
  def node(node_name), do: %__MODULE__{type: :node, id: to_string(node_name), config: %{}}

  @doc """
  Creates a new FLAME pool target.
  """
  def flame(pool_name, config \\ %{}) do
    %__MODULE__{type: :flame, id: to_string(pool_name), config: config}
  end

  @doc """
  Parses a raw map or string into a Target struct.
  """
  def parse(%__MODULE__{} = target), do: target

  def parse(target_map) when is_map(target_map) do
    type =
      try do
        target_map
        |> Map.get("type", "local")
        |> to_string()
        |> String.to_existing_atom()
      rescue
        ArgumentError -> :local
      end

    %__MODULE__{
      type: type,
      id: Map.get(target_map, "id"),
      config: Map.get(target_map, "config", %{})
    }
  end

  def parse(_), do: local()
end
