defmodule Imgd.Credentials.ProviderRegistry do
  @moduledoc """
  Registry for credential providers.

  Manages the mapping between provider names (atoms) and their implementation modules.
  """

  @providers %{
    built_in: Imgd.Credentials.Providers.BuiltIn
  }

  @doc """
  Returns the provider module for a given provider name.
  Defaults to :built_in.
  """
  def get_provider(provider_name \\ :built_in) do
    Map.get(@providers, provider_name) || {:error, :unknown_provider}
  end

  @doc """
  Lists all available providers.
  """
  def list_providers do
    Map.keys(@providers)
  end

  # Configuration management would go here - for now we use compile-time map
  # but in future this could use application config to allow runtime registration.
end
