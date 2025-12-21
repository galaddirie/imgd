defmodule Imgd.Runtime.Token do
  @moduledoc """
  Execution token carrying data between nodes.

  Tokens wrap node outputs with routing and lineage metadata,
  enabling control flow (branching) and observability.

  ## Structure

  - `data` - The actual output value (backward compatible with raw outputs)
  - `items` - Optional list of Items for collection processing
  - `route` - Output port name (default "main", or "true"/"false" for branches)
  - `source` - Origin information for debugging
  - `lineage` - Chain of node IDs that contributed to this token

  ## Usage

  Executors can return either raw data (wrapped automatically) or tokens:

      # Simple - auto-wrapped
      {:ok, %{"status" => 200}}

      # Explicit token with routing
      {:ok, Token.new(%{"error" => msg}, route: "error")}

      # Items for collection processing
      {:ok, Token.with_items([item1, item2, item3])}
  """

  alias Imgd.Runtime.Item

  @type t :: %__MODULE__{
          data: term(),
          items: [Item.t()] | nil,
          route: String.t(),
          source_node_id: String.t() | nil,
          source_output: String.t(),
          lineage: [String.t()],
          metadata: map()
        }

  @enforce_keys []
  defstruct [
    :data,
    :items,
    :source_node_id,
    route: "main",
    source_output: "main",
    lineage: [],
    metadata: %{}
  ]

  @doc """
  Creates a new token with the given data.

  ## Options

  - `:route` - Output port name (default: "main")
  - `:source_node_id` - Node that produced this token
  - `:source_output` - Output port on source node
  - `:lineage` - List of contributing node IDs
  - `:metadata` - Additional metadata
  """
  @spec new(term(), keyword()) :: t()
  def new(data, opts \\ []) do
    %__MODULE__{
      data: data,
      items: nil,
      route: Keyword.get(opts, :route, "main"),
      source_node_id: Keyword.get(opts, :source_node_id),
      source_output: Keyword.get(opts, :source_output, "main"),
      lineage: Keyword.get(opts, :lineage, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates a token containing items for collection processing.

  The `data` field will contain the list of item json values for
  backward compatibility with nodes that don't understand items.
  """
  @spec with_items([Item.t()] | [map()], keyword()) :: t()
  def with_items(items, opts \\ []) when is_list(items) do
    normalized_items = Enum.with_index(items, &normalize_item/2)

    %__MODULE__{
      data: Enum.map(normalized_items, & &1.json),
      items: normalized_items,
      route: Keyword.get(opts, :route, "main"),
      source_node_id: Keyword.get(opts, :source_node_id),
      source_output: Keyword.get(opts, :source_output, "main"),
      lineage: Keyword.get(opts, :lineage, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Wraps a raw value in a token if not already a token.

  Used by the runtime to normalize executor outputs.
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = token), do: token
  def wrap(data), do: new(data)

  @doc """
  Unwraps token data, returning raw value for backward compatibility.
  """
  @spec unwrap(t() | term()) :: term()
  def unwrap(%__MODULE__{items: nil, data: data}), do: data
  def unwrap(%__MODULE__{items: items}) when is_list(items), do: Enum.map(items, & &1.json)
  def unwrap(other), do: other

  @doc """
  Returns true if the token contains items.
  """
  @spec has_items?(t()) :: boolean()
  def has_items?(%__MODULE__{items: items}), do: is_list(items) and items != []
  def has_items?(_), do: false

  @doc """
  Returns the items if present, or wraps data as a single item.
  """
  @spec to_items(t()) :: [Item.t()]
  def to_items(%__MODULE__{items: items}) when is_list(items), do: items

  def to_items(%__MODULE__{data: data}) do
    [Item.new(data, 0)]
  end

  @doc """
  Adds source information to a token.
  """
  @spec with_source(t(), String.t(), String.t()) :: t()
  def with_source(%__MODULE__{} = token, node_id, output \\ "main") do
    lineage =
      if node_id in token.lineage do
        token.lineage
      else
        token.lineage ++ [node_id]
      end

    %{token | source_node_id: node_id, source_output: output, lineage: lineage}
  end

  @doc """
  Creates a skip token indicating this branch is inactive.
  """
  @spec skip(String.t(), keyword()) :: t()
  def skip(reason, opts \\ []) do
    %__MODULE__{
      data: nil,
      items: nil,
      route: Keyword.get(opts, :route, "main"),
      source_node_id: Keyword.get(opts, :source_node_id),
      source_output: Keyword.get(opts, :source_output, "main"),
      lineage: Keyword.get(opts, :lineage, []),
      metadata: %{skipped: true, skip_reason: reason}
    }
  end

  @doc """
  Returns true if this is a skip token.
  """
  @spec skipped?(t()) :: boolean()
  def skipped?(%__MODULE__{metadata: %{skipped: true}}), do: true
  def skipped?(_), do: false

  @doc """
  Maps over items in the token, preserving token metadata.
  """
  @spec map_items(t(), (Item.t() -> Item.t())) :: t()
  def map_items(%__MODULE__{items: nil} = token, _fun), do: token

  def map_items(%__MODULE__{items: items} = token, fun) when is_list(items) do
    new_items = Enum.map(items, fun)
    %{token | items: new_items, data: Enum.map(new_items, & &1.json)}
  end

  @doc """
  Filters items in the token.
  """
  @spec filter_items(t(), (Item.t() -> boolean())) :: t()
  def filter_items(%__MODULE__{items: nil} = token, _fun), do: token

  def filter_items(%__MODULE__{items: items} = token, fun) when is_list(items) do
    new_items = Enum.filter(items, fun)
    %{token | items: new_items, data: Enum.map(new_items, & &1.json)}
  end

  # Normalizes raw maps to Item structs
  defp normalize_item(%Item{} = item, _index), do: item

  defp normalize_item(%{"json" => json} = map, index),
    do: Item.new(json, index, Map.get(map, "binary"))

  defp normalize_item(data, index), do: Item.new(data, index)
end
