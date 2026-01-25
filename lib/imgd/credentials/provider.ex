defmodule Imgd.Credentials.Provider do
  @moduledoc """
  Behaviour for pluggable credential providers.

  A provider is responsible for fetching, storing, and managing the lifecycle
  of sensitive credential data.

  ## Built-in Providers
  - `Imgd.Credentials.Providers.BuiltIn` - Encrypted database storage

  ## External Providers (implement as needed)
  - AWS Secrets Manager
  - GCP Secret Manager
  - HashiCorp Vault
  """

  @type credential_ref :: String.t()
  @type credential_data :: map()
  @type opts :: keyword()

  @callback fetch(credential_ref, opts) :: {:ok, credential_data} | {:error, term()}

  # Optional callbacks for full lifecycle management - currently we focus on fetch
  # Logic for store/rotate/delete might be provider-specific or handled by the
  # Credentials context for built-in types.

  @optional_callbacks store: 2, rotate: 3, delete: 2

  @callback store(credential_data, opts) :: {:ok, credential_ref} | {:error, term()}
  @callback rotate(credential_ref, credential_data, opts) ::
              {:ok, credential_ref} | {:error, term()}
  @callback delete(credential_ref, opts) :: :ok | {:error, term()}
end
