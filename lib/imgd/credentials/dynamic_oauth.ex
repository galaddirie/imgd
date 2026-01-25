defmodule Imgd.Credentials.DynamicOAuth do
  @moduledoc """
  Handles OAuth2 flows dynamically based on Credential configurations.

  Replaces Ueberauth with direct OAuth2 flows using Req HTTP client,
  enabling per-credential OAuth app configuration stored in the database.

  ## Security

  State parameters are signed using Phoenix.Token to prevent CSRF attacks
  and to securely pass the credential_id and user_id through the OAuth flow.
  """

  alias Imgd.Credentials.{Credential, OAuthConfig}

  @state_salt "oauth_state_v1"
  @state_max_age 600

  @doc """
  Builds the OAuth authorization URL with a signed state parameter.

  The state parameter contains the credential_id and user_id, signed with
  Phoenix.Token to prevent CSRF and ensure the callback can identify
  the correct credential configuration.

  ## Options

  - `:redirect_uri` - Required. The callback URL
  - `:extra_params` - Optional. Additional query params to include

  ## Example

      {:ok, url} = DynamicOAuth.authorize_url(credential, user_id, "https://example.com/callback")
      # Redirect user to url
  """
  @spec authorize_url(Credential.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def authorize_url(%Credential{} = credential, user_id, redirect_uri, opts \\ [])
      when is_binary(user_id) and is_binary(redirect_uri) do
    with {:ok, auth_url} <- get_authorization_url(credential),
         {:ok, decrypted} <- Credential.decrypt(credential),
         state <- sign_state(credential.id, user_id) do
      client_id = decrypted.data["client_id"]

      params =
        %{
          client_id: client_id,
          redirect_uri: redirect_uri,
          response_type: "code",
          state: state
        }
        |> maybe_add_scopes(credential.oauth_scopes)
        |> Map.merge(Keyword.get(opts, :extra_params, %{}))
        |> add_provider_specific_params(credential.oauth_provider_slug)

      url = "#{auth_url}?#{URI.encode_query(params)}"
      {:ok, url}
    end
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.

  ## Example

      {:ok, tokens} = DynamicOAuth.exchange_code(credential, "auth_code", "https://example.com/callback")
      # tokens = %{"access_token" => "...", "refresh_token" => "...", ...}
  """
  @spec exchange_code(Credential.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(%Credential{} = credential, code, redirect_uri)
      when is_binary(code) and is_binary(redirect_uri) do
    with {:ok, token_url} <- get_token_url(credential),
         {:ok, decrypted} <- Credential.decrypt(credential) do
      body = %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: decrypted.data["client_id"],
        client_secret: decrypted.data["client_secret"]
      }

      headers = token_request_headers(credential.oauth_provider_slug)

      case Req.post(token_url, form: body, headers: headers, decode_body: false) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          parse_token_response(body, credential.oauth_provider_slug)

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_exchange_failed, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  @doc """
  Fetches user information from the OAuth provider.

  ## Example

      {:ok, user_info} = DynamicOAuth.fetch_user_info(credential, "access_token")
      # user_info = %{"email" => "...", "name" => "...", ...}
  """
  @spec fetch_user_info(Credential.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_user_info(%Credential{} = credential, access_token) when is_binary(access_token) do
    case OAuthConfig.get_userinfo_url(credential) do
      nil ->
        {:error, :userinfo_url_not_configured}

      userinfo_url ->
        headers = [{"authorization", "Bearer #{access_token}"}]

        case Req.get(userinfo_url, headers: headers) do
          {:ok, %{status: 200, body: body}} when is_map(body) ->
            {:ok, normalize_user_info(body, credential.oauth_provider_slug)}

          {:ok, %{status: status, body: body}} ->
            {:error, {:userinfo_failed, status, body}}

          {:error, reason} ->
            {:error, {:http_error, reason}}
        end
    end
  end

  @doc """
  Refreshes an access token using a refresh token.

  ## Example

      {:ok, new_tokens} = DynamicOAuth.refresh_token(credential, "refresh_token")
  """
  @spec refresh_token(Credential.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_token(%Credential{} = credential, refresh_token) when is_binary(refresh_token) do
    with {:ok, token_url} <- get_token_url(credential),
         {:ok, decrypted} <- Credential.decrypt(credential) do
      body = %{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: decrypted.data["client_id"],
        client_secret: decrypted.data["client_secret"]
      }

      headers = token_request_headers(credential.oauth_provider_slug)

      case Req.post(token_url, form: body, headers: headers, decode_body: false) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          parse_token_response(body, credential.oauth_provider_slug)

        {:ok, %{status: status, body: body}} ->
          {:error, {:token_refresh_failed, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  @doc """
  Signs a state parameter containing credential_id and user_id.

  The state is valid for 10 minutes.
  """
  @spec sign_state(String.t(), String.t()) :: String.t()
  def sign_state(credential_id, user_id) do
    data = %{
      credential_id: credential_id,
      user_id: user_id,
      timestamp: System.system_time(:second)
    }

    Phoenix.Token.sign(ImgdWeb.Endpoint, @state_salt, data)
  end

  @doc """
  Verifies and decodes a state parameter.

  Returns `{:ok, %{credential_id: id, user_id: id}}` if valid,
  or `{:error, reason}` if invalid or expired.
  """
  @spec verify_state(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_state(state) when is_binary(state) do
    case Phoenix.Token.verify(ImgdWeb.Endpoint, @state_salt, state, max_age: @state_max_age) do
      {:ok, %{credential_id: credential_id, user_id: user_id}} ->
        {:ok, %{credential_id: credential_id, user_id: user_id}}

      {:error, reason} ->
        {:error, {:invalid_state, reason}}
    end
  end

  # Private functions

  defp get_authorization_url(credential) do
    case OAuthConfig.get_authorization_url(credential) do
      nil -> {:error, :authorization_url_not_configured}
      url -> {:ok, url}
    end
  end

  defp get_token_url(credential) do
    case OAuthConfig.get_token_url(credential) do
      nil -> {:error, :token_url_not_configured}
      url -> {:ok, url}
    end
  end

  defp maybe_add_scopes(params, []), do: params
  defp maybe_add_scopes(params, scopes), do: Map.put(params, :scope, Enum.join(scopes, " "))

  # Provider-specific authorization params
  defp add_provider_specific_params(params, :google) do
    Map.merge(params, %{access_type: "offline", prompt: "consent"})
  end

  defp add_provider_specific_params(params, _), do: params

  # GitHub returns tokens as form-encoded by default, need Accept header for JSON
  defp token_request_headers(:github) do
    [{"accept", "application/json"}]
  end

  defp token_request_headers(_), do: []

  defp parse_token_response(body, provider_slug) when is_binary(body) do
    cond do
      String.starts_with?(body, "{") ->
        case Jason.decode(body) do
          {:ok, parsed} -> normalize_token_response(parsed, provider_slug)
          {:error, _} -> {:error, {:invalid_json, body}}
        end

      true ->
        # Form-encoded response (e.g., GitHub fallback)
        parsed = URI.decode_query(body)
        normalize_token_response(parsed, provider_slug)
    end
  end

  defp parse_token_response(body, provider_slug) when is_map(body) do
    normalize_token_response(body, provider_slug)
  end

  defp normalize_token_response(response, _provider_slug) do
    expires_at =
      cond do
        response["expires_at"] -> response["expires_at"]
        response["expires_in"] -> System.system_time(:second) + parse_int(response["expires_in"])
        true -> nil
      end

    tokens = %{
      "access_token" => response["access_token"],
      "refresh_token" => response["refresh_token"],
      "token_type" => response["token_type"] || "Bearer",
      "scope" => response["scope"],
      "expires_at" => expires_at
    }

    # Filter out nil values
    tokens = Map.reject(tokens, fn {_, v} -> is_nil(v) end)

    if tokens["access_token"] do
      {:ok, tokens}
    else
      {:error, {:no_access_token, response}}
    end
  end

  defp normalize_user_info(body, :google) do
    %{
      "email" => body["email"],
      "name" => body["name"],
      "avatar" => body["picture"],
      "uid" => body["id"]
    }
  end

  defp normalize_user_info(body, :github) do
    %{
      "email" => body["email"],
      "name" => body["name"] || body["login"],
      "avatar" => body["avatar_url"],
      "uid" => to_string(body["id"]),
      "nickname" => body["login"]
    }
  end

  defp normalize_user_info(body, :slack) do
    user = body["user"] || %{}

    %{
      "email" => user["email"],
      "name" => user["name"],
      "avatar" => user["image_192"] || user["image_72"],
      "uid" => user["id"]
    }
  end

  defp normalize_user_info(body, _) do
    %{
      "email" => body["email"],
      "name" => body["name"],
      "avatar" => body["picture"] || body["avatar_url"],
      "uid" => body["id"] || body["sub"]
    }
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)
  defp parse_int(_), do: 0
end
