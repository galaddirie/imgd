defmodule Imgd.Credentials.OAuthConfig do
  @moduledoc """
  OAuth configuration helper for credentials.

  Provides default OAuth endpoints for known providers (Google, GitHub, Slack)
  and helper functions to retrieve the appropriate URLs for OAuth flows.
  """

  alias Imgd.Credentials.Credential

  @default_endpoints %{
    google: %{
      authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://www.googleapis.com/oauth2/v2/userinfo"
    },
    github: %{
      authorization_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      userinfo_url: "https://api.github.com/user"
    },
    slack: %{
      authorization_url: "https://slack.com/oauth/v2/authorize",
      token_url: "https://slack.com/api/oauth.v2.access",
      userinfo_url: "https://slack.com/api/users.identity"
    }
  }

  @doc """
  Returns the authorization URL for this credential.
  Uses custom URL if set, otherwise returns the default for the oauth_provider_slug.
  """
  @spec get_authorization_url(Credential.t()) :: String.t() | nil
  def get_authorization_url(%Credential{authorization_url: url})
      when is_binary(url) and url != "",
      do: url

  def get_authorization_url(%Credential{oauth_provider_slug: slug}) when not is_nil(slug) do
    get_in(@default_endpoints, [slug, :authorization_url])
  end

  def get_authorization_url(_), do: nil

  @doc """
  Returns the token URL for this credential.
  Uses custom URL if set, otherwise returns the default for the oauth_provider_slug.
  """
  @spec get_token_url(Credential.t()) :: String.t() | nil
  def get_token_url(%Credential{token_url: url}) when is_binary(url) and url != "", do: url

  def get_token_url(%Credential{oauth_provider_slug: slug}) when not is_nil(slug) do
    get_in(@default_endpoints, [slug, :token_url])
  end

  def get_token_url(_), do: nil

  @doc """
  Returns the user info URL for this credential's provider.
  """
  @spec get_userinfo_url(Credential.t()) :: String.t() | nil
  def get_userinfo_url(%Credential{oauth_provider_slug: slug}) when not is_nil(slug) do
    get_in(@default_endpoints, [slug, :userinfo_url])
  end

  def get_userinfo_url(_), do: nil

  @doc """
  Returns the default endpoints map for all providers.
  """
  def default_endpoints, do: @default_endpoints

  @doc """
  Returns the default scopes for a given provider.
  """
  @spec default_scopes(atom()) :: [String.t()]
  def default_scopes(:google), do: ["openid", "email", "profile"]
  def default_scopes(:github), do: ["user:email"]
  def default_scopes(:slack), do: ["identity.basic", "identity.email"]
  def default_scopes(_), do: []
end
