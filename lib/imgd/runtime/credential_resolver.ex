defmodule Imgd.Runtime.CredentialResolver do
  @moduledoc """
  Resolves credential references in step configs at runtime.

  ## Security
  - Credentials are resolved just-in-time before step execution
  - Resolved values are never stored in execution context (if proper care is taken)
  - All credential access is audit logged
  """

  alias Imgd.Credentials
  alias Imgd.Credentials.Reference

  @doc """
  Resolves all credential references in a config map.
  Returns {:ok, config_with_secrets} or {:error, reason}.
  """
  def resolve(config, scope, environment \\ :production) do
    refs = Reference.extract_refs(config)

    if Enum.empty?(refs) do
      {:ok, config}
    else
      # Resolve all refs
      results =
        Enum.map(refs, fn ref ->
          case Credentials.resolve_credential(scope, ref.credential_id, environment) do
            {:ok, credential} ->
              {:ok, {ref, credential}}

            {:error, reason} ->
              {:error, {ref, reason}}
          end
        end)

      failures = Enum.filter(results, fn {status, _} -> status == :error end)

      if Enum.empty?(failures) do
        resolved_pairs = Enum.map(results, fn {:ok, pair} -> pair end)
        {:ok, inject_secrets(config, resolved_pairs)}
      else
        first_error = hd(failures) |> elem(1)
        {:error, {:resolution_failed, first_error}}
      end
    end
  end

  @doc """
  Extracts credential references from a config map.
  Convenience function that delegates to Reference.extract_refs/1.
  """
  def extract_refs(config) do
    Reference.extract_refs(config)
  end

  defp inject_secrets(config, []) do
    config
  end

  defp inject_secrets(config, [{ref, credential} | rest]) do
    config = inject_single_ref(config, ref, credential)
    inject_secrets(config, rest)
  end

  defp inject_single_ref(config, ref, credential) do
    # 1. Get the value to inject
    value =
      if ref.field do
        Map.get(credential.data, ref.field)
      else
        credential.data
      end

    # 2. Inject it
    # We need to replace the original ref in the config.
    # Since Reference.extract_refs handles nested maps, we need to traverse and replace.
    # This is tricky because extract_refs flattened the structure.

    # Simpler approach: Recursive traversal to find and replace.
    deep_replace_ref(config, ref, value)
  end

  defp deep_replace_ref(map, ref, value) when is_map(map) do
    if Map.has_key?(map, "__credential_ref") and
         map["__credential_ref"]["id"] == ref.credential_id and
         map["__credential_ref"]["field"] == ref.field do
      # Found the ref object. Replace it with the value.
      # Need to handle `inject_as`.
      # If value is simple string and inject_as is bearer_token, wrap it?
      # For now, just return the value.
      value
    else
      Map.new(map, fn {k, v} -> {k, deep_replace_ref(v, ref, value)} end)
    end
  end

  defp deep_replace_ref(list, ref, value) when is_list(list) do
    Enum.map(list, fn v -> deep_replace_ref(v, ref, value) end)
  end

  defp deep_replace_ref(str, ref, value) when is_binary(str) do
    # Handle string replacement: "$credential:id:field"
    # We reconstruct the string ref we are looking for
    target_str =
      if ref.field do
        "$credential:#{ref.credential_id}:#{ref.field}"
      else
        "$credential:#{ref.credential_id}"
      end

    if str == target_str do
      value
    else
      str
    end
  end

  defp deep_replace_ref(other, _ref, _value), do: other

  @doc """
  Creates a masked version of config for logging/display.
  Replaces credential values with "***REDACTED***".

  This function recursively traverses the config and redacts:
  1. Any credential reference objects (__credential_ref)
  2. Any keys that appear to contain sensitive data (password, secret, token, key, etc.)
  3. Any string values that match credential reference patterns

  Use this before logging resolved configurations to prevent secrets from leaking.
  """
  def mask(config) do
    deep_mask(config)
  end

  @sensitive_patterns ~w(password secret token key authorization api_key access_token refresh_token bearer credential auth)

  defp deep_mask(map) when is_map(map) do
    cond do
      # If this is a credential reference object, mask it
      Map.has_key?(map, "__credential_ref") ->
        "***CREDENTIAL_REF***"

      # Otherwise recursively mask the map
      true ->
        Map.new(map, fn {k, v} ->
          if sensitive_key?(k) do
            {k, "***REDACTED***"}
          else
            {k, deep_mask(v)}
          end
        end)
    end
  end

  defp deep_mask(list) when is_list(list) do
    Enum.map(list, &deep_mask/1)
  end

  defp deep_mask(str) when is_binary(str) do
    # Mask string credential references
    if String.contains?(str, "$credential:") do
      String.replace(str, ~r/\$credential:[a-f0-9\-]+(?::[a-zA-Z0-9_]+)?/, "***CREDENTIAL_REF***")
    else
      str
    end
  end

  defp deep_mask(other), do: other

  defp sensitive_key?(k) do
    key = to_string(k) |> String.downcase()
    Enum.any?(@sensitive_patterns, &String.contains?(key, &1))
  end
end
