defmodule Imgd.Workers.OAuthTokenRefresher do
  @moduledoc """
  Background worker that refreshes OAuth tokens before they expire.

  This worker uses the credential's embedded OAuth configuration (client_id,
  client_secret stored in encrypted_data) for the refresh request.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Imgd.Credentials

  @impl true
  def perform(%Oban.Job{args: %{"credential_id" => id}}) do
    case Imgd.Repo.get(Imgd.Credentials.Credential, id) do
      nil ->
        {:cancel, :credential_not_found}

      credential ->
        case Credentials.refresh_oauth_token(credential) do
          {:ok, _updated} ->
            :ok

          {:error, :not_oauth_credential} ->
            {:cancel, :not_oauth_credential}

          {:error, :no_refresh_token} ->
            {:cancel, :no_refresh_token}

          {:error, {:oauth_refresh_failed, reason}} ->
            {:error, {:refresh_failed, reason}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
