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
