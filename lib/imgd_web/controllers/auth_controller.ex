defmodule ImgdWeb.AuthController do
  @moduledoc """
  Handles OAuth authentication flows using database-stored credential configurations.

  This controller replaces Ueberauth with direct OAuth2 flows, enabling per-credential
  OAuth app configuration stored in the database.
  """
  use ImgdWeb, :controller

  alias Imgd.Credentials
  alias Imgd.Credentials.{DynamicOAuth, OAuthConfig}
  alias Imgd.Accounts.Scope

  @doc """
  Initiates the OAuth flow by redirecting to the provider's authorization URL.

  The credential_id comes from the route parameter and identifies which
  credential configuration to use for OAuth.
  """
  def request(conn, %{"credential_id" => credential_id}) do
    user = conn.assigns.current_user
    scope = Scope.for_user(user)

    case Credentials.get_credential(scope, credential_id) do
      {:ok, credential} ->
        redirect_uri = callback_url(conn)

        case DynamicOAuth.authorize_url(credential, user.id, redirect_uri) do
          {:ok, authorize_url} ->
            redirect(conn, external: authorize_url)

          {:error, reason} ->
            conn
            |> put_flash(:error, "Failed to build authorization URL: #{inspect(reason)}")
            |> redirect(to: ~p"/users/settings/credentials")
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Credential not found")
        |> redirect(to: ~p"/users/settings/credentials")
    end
  end

  @doc """
  Handles the OAuth callback with an authorization code.

  The state parameter contains the signed credential_id and user_id,
  which is verified to prevent CSRF attacks.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, %{credential_id: credential_id, user_id: user_id}} <-
           DynamicOAuth.verify_state(state),
         :ok <- verify_current_user(conn, user_id),
         {:ok, credential} <- get_credential_for_callback(credential_id),
         redirect_uri <- callback_url(conn),
         {:ok, tokens} <- DynamicOAuth.exchange_code(credential, code, redirect_uri),
         {:ok, user_info} <- fetch_user_info_if_available(credential, tokens) do
      user = conn.assigns.current_user
      scope = Scope.for_user(user)

      case Credentials.complete_oauth_connection(scope, credential, tokens, user_info) do
        {:ok, _credential} ->
          provider_name = format_provider_name(credential.oauth_provider_slug)

          conn
          |> put_flash(:info, "Successfully connected #{provider_name}!")
          |> redirect(to: ~p"/users/settings/credentials")

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to save credential: #{inspect(reason)}")
          |> redirect(to: ~p"/users/settings/credentials")
      end
    else
      {:error, {:invalid_state, _reason}} ->
        conn
        |> put_flash(:error, "Invalid or expired OAuth state. Please try again.")
        |> redirect(to: ~p"/users/settings/credentials")

      {:error, :user_mismatch} ->
        conn
        |> put_flash(:error, "OAuth session mismatch. Please try again.")
        |> redirect(to: ~p"/users/settings/credentials")

      {:error, {:token_exchange_failed, status, body}} ->
        conn
        |> put_flash(:error, "Token exchange failed (#{status}): #{inspect(body)}")
        |> redirect(to: ~p"/users/settings/credentials")

      {:error, reason} ->
        conn
        |> put_flash(:error, "OAuth failed: #{inspect(reason)}")
        |> redirect(to: ~p"/users/settings/credentials")
    end
  end

  def callback(conn, %{"error" => error} = params) do
    error_description = params["error_description"] || "Unknown error"

    conn
    |> put_flash(:error, "Authentication failed: #{error} - #{error_description}")
    |> redirect(to: ~p"/users/settings/credentials")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid OAuth callback")
    |> redirect(to: ~p"/users/settings/credentials")
  end

  # Private functions

  defp callback_url(conn) do
    url(conn, ~p"/auth/credentials/callback")
  end

  defp verify_current_user(conn, user_id) do
    if conn.assigns.current_user && conn.assigns.current_user.id == user_id do
      :ok
    else
      {:error, :user_mismatch}
    end
  end

  defp get_credential_for_callback(credential_id) do
    case Imgd.Repo.get(Imgd.Credentials.Credential, credential_id) do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  end

  defp fetch_user_info_if_available(credential, tokens) do
    case OAuthConfig.get_userinfo_url(credential) do
      nil ->
        # No userinfo URL configured, return minimal info
        {:ok, %{}}

      _url ->
        case DynamicOAuth.fetch_user_info(credential, tokens["access_token"]) do
          {:ok, user_info} -> {:ok, user_info}
          {:error, _reason} -> {:ok, %{}}
        end
    end
  end

  defp format_provider_name(provider_slug) do
    provider_slug
    |> to_string()
    |> String.capitalize()
  end
end
