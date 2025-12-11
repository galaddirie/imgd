defmodule Imgd.ContextHelpers do
  @moduledoc """
  Shared helper functions for context modules.
  """

  @doc """
  Normalizes input attributes to a map.

  Handles nil, maps, and keyword lists. Raises on invalid input.

  ## Examples

      iex> normalize_attrs(nil)
      %{}

      iex> normalize_attrs(%{name: "test"})
      %{name: "test"}

      iex> normalize_attrs([name: "test"])
      %{name: "test"}

      iex> normalize_attrs("invalid")
      ** (ArgumentError) expected nil, map, or keyword list, got: "invalid"
  """
  def normalize_attrs(nil), do: %{}
  def normalize_attrs(attrs) when is_map(attrs), do: attrs
  def normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)

  def normalize_attrs(other) do
    raise ArgumentError, "expected nil, map, or keyword list, got: #{inspect(other)}"
  end

  @doc """
  Normalizes attribute keys to atoms.

  Useful when you want to accept both string and atom keys but
  work with atoms internally.

  ## Options
    * `:only` - list of keys to normalize (others passed through)
    * `:except` - list of keys to skip

  ## Examples

      iex> normalize_keys(%{"name" => "test", "count" => 1}, only: [:name])
      %{name: "test", "count" => 1}
  """
  def normalize_keys(attrs, opts \\ []) when is_map(attrs) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except, [])

    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      normalized_key = do_normalize_key(key, only, except)
      Map.put(acc, normalized_key, value)
    end)
  end

  defp do_normalize_key(key, only, except) when is_binary(key) do
    atom_key = String.to_existing_atom(key)

    cond do
      atom_key in except -> key
      is_nil(only) -> atom_key
      atom_key in only -> atom_key
      true -> key
    end
  rescue
    ArgumentError -> key
  end

  defp do_normalize_key(key, _only, _except), do: key

  @doc """
  Extracts the user ID from a scope, raising if not present.
  """
  def scope_user_id!(%{user: %{id: user_id}}) when not is_nil(user_id), do: user_id
  def scope_user_id!(_), do: raise(ArgumentError, "scope with user is required")
end
