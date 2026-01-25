defmodule Imgd.Credentials.Reference do
  @moduledoc """
  Helper module for handling credential references in step configurations.
  """

  @type ref :: %{
          id: String.t(),
          credential_id: String.t(),
          field: String.t() | nil,
          inject_as: String.t() | nil
        }

  @doc """
  Extracts all credential references from a config map.
  Returns a list of references.
  """
  def extract_refs(config) when is_map(config) do
    do_extract_refs(config, [])
  end

  def extract_refs(_), do: []

  defp do_extract_refs(map, acc) when is_map(map) do
    if Map.has_key?(map, "__credential_ref") do
      [normalize_struct_ref(map["__credential_ref"]) | acc]
    else
      Enum.reduce(map, acc, fn {_k, v}, current_acc ->
        do_extract_refs(v, current_acc)
      end)
    end
  end

  defp do_extract_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn v, current_acc ->
      do_extract_refs(v, current_acc)
    end)
  end

  defp do_extract_refs(str, acc) when is_binary(str) do
    regex = ~r/\$credential:([a-zA-Z0-9_\-]+)(?::([a-zA-Z0-9_\-]+))?/

    short_refs =
      Regex.scan(regex, str)
      |> Enum.map(fn match ->
        case match do
          [_, id, field] when field != "" ->
            %{credential_id: id, field: field, inject_as: nil, source: :string}

          [_, id] ->
            %{credential_id: id, field: nil, inject_as: nil, source: :string}

          [_, id, ""] ->
            %{credential_id: id, field: nil, inject_as: nil, source: :string}
        end
      end)

    short_refs ++ acc
  end

  defp do_extract_refs(_, acc), do: acc

  defp normalize_struct_ref(ref_map) do
    %{
      # This is the credential ID
      id: ref_map["id"],
      credential_id: ref_map["id"],
      field: ref_map["field"],
      inject_as: ref_map["inject_as"]
    }
  end

  # parse_string_ref is no longer used directly
end
