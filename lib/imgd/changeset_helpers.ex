defmodule Imgd.ChangesetHelpers do
  @moduledoc """
  Shared changeset validation helpers used across schemas.
  """
  import Ecto.Changeset

  @doc """
  Validates that a field is a map.

  ## Options
    * `:allow_nil` - if true, nil values pass validation (default: false)

  ## Examples

      changeset
      |> validate_map_field(:config)
      |> validate_map_field(:error, allow_nil: true)
  """
  def validate_map_field(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_map(value) -> []
        is_nil(value) and Keyword.get(opts, :allow_nil, false) -> []
        true -> [{field, "must be a map"}]
      end
    end)
  end

  @doc """
  Validates that a field is a list containing only maps.

  ## Options
    * `:allow_nil` - if true, nil values pass validation (default: false)
    * `:allow_empty` - if true, empty lists pass validation (default: true)

  ## Examples

      changeset
      |> validate_list_of_maps(:events)
      |> validate_list_of_maps(:logs, allow_nil: true)
  """
  def validate_list_of_maps(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      allow_nil = Keyword.get(opts, :allow_nil, false)
      allow_empty = Keyword.get(opts, :allow_empty, true)

      cond do
        is_nil(value) and allow_nil ->
          []

        is_nil(value) ->
          [{field, "can't be nil"}]

        not is_list(value) ->
          [{field, "must be a list of maps"}]

        value == [] and not allow_empty ->
          [{field, "can't be empty"}]

        Enum.all?(value, &is_map/1) ->
          []

        true ->
          [{field, "must only contain map entries"}]
      end
    end)
  end

  @doc """
  Validates that an integer field is positive (> 0).
  Only validates if the field is present and not nil.
  """
  def validate_positive_integer(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) -> []
        is_integer(value) and value > 0 -> []
        true -> [{field, "must be a positive integer"}]
      end
    end)
  end

  @doc """
  Validates that an integer field is non-negative (>= 0).
  Only validates if the field is present and not nil.
  """
  def validate_non_negative_integer(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) -> []
        is_integer(value) and value >= 0 -> []
        true -> [{field, "must be a non-negative integer"}]
      end
    end)
  end

  @doc """
  Validates that a string field is a valid 64-character lowercase hex hash.
  Used for content hashes (SHA-256).
  """
  def validate_hex_hash(changeset, field, opts \\ []) do
    length = Keyword.get(opts, :length, 64)

    validate_change(changeset, field, fn ^field, hash ->
      cond do
        is_binary(hash) and byte_size(hash) == length and String.match?(hash, ~r/^[0-9a-f]+$/) ->
          []

        is_binary(hash) ->
          [{field, "must be a #{length}-character lowercase hex string"}]

        true ->
          [{field, "must be a string"}]
      end
    end)
  end
end
