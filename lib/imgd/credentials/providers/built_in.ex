defmodule Imgd.Credentials.Providers.BuiltIn do
  @moduledoc """
  Default credential provider using the internal encrypted database.
  """
  @behaviour Imgd.Credentials.Provider

  alias Imgd.Credentials

  @impl true
  def fetch(credential_id, opts) do
    with {:ok, scope} <- Keyword.fetch(opts, :scope),
         environment = Keyword.get(opts, :environment, :production) do
      case Credentials.resolve_credential(scope, credential_id, environment) do
        {:ok, credential} -> {:ok, credential.data}
        {:error, _} = error -> error
      end
    else
      :error -> {:error, :missing_scope}
    end
  end
end
