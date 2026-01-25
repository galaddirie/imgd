defmodule Imgd.Credentials do
  @moduledoc """
  Context for managing user credentials with encryption at rest.

  All functions accept a Scope for authorization.
  """

  import Ecto.Query, warn: false
  alias Imgd.Repo

  alias Imgd.Credentials.{Credential, CredentialType, AuditLog, DynamicOAuth}
  alias Imgd.Accounts.Scope

  @doc """
  Lists credentials accessible to the given scope.
  """
  def list_credentials(%Scope{} = scope, _opts \\ []) do
    user_id = scope.user.id

    from(c in Credential,
      where: c.user_id == ^user_id,
      order_by: [desc: c.inserted_at],
      preload: [:credential_type]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single credential.
  User must own the credential to access it.
  """
  def get_credential(%Scope{} = scope, id) do
    case Repo.get(Credential, id) |> Repo.preload([:credential_type]) do
      nil ->
        {:error, :not_found}

      credential ->
        if Scope.can_view_credential?(scope, credential) do
          {:ok, credential}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a credential.
  """
  def create_credential(%Scope{} = scope, attrs) do
    user_id = scope.user.id

    result =
      %Credential{}
      # Always force the user_id from scope
      |> Credential.create_changeset(Map.put(attrs, :user_id, user_id))
      |> Repo.insert()

    case result do
      {:ok, credential} ->
        log_credential_access(credential, scope, :created)
        {:ok, credential}

      error ->
        error
    end
  end

  @doc """
  Updates a credential.
  """
  def update_credential(%Scope{} = scope, %Credential{} = credential, attrs) do
    if Scope.can_view_credential?(scope, credential) do
      result =
        credential
        |> Credential.update_changeset(attrs)
        |> Repo.update()

      case result do
        {:ok, updated} ->
          log_credential_access(updated, scope, :updated)
          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Deletes a credential.
  """
  def delete_credential(%Scope{} = scope, %Credential{} = credential) do
    if Scope.can_view_credential?(scope, credential) do
      # Log before deletion (while we still have the record)
      log_credential_access(credential, scope, :deleted)
      Repo.delete(credential)
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # Credential Types
  # ============================================================================

  @doc """
  Lists all available credential types.
  """
  def list_credential_types(opts \\ []) do
    base_query = from(t in CredentialType, order_by: [asc: t.name])

    base_query
    |> filter_by_search(opts[:search])
    |> filter_by_category(opts[:category])
    |> limit_results(opts[:limit])
    |> Repo.all()
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    search_pattern = "%#{search_term}%"

    from t in query,
      where:
        ilike(t.name, ^search_pattern) or
          ilike(t.slug, ^search_pattern) or
          ilike(t.category, ^search_pattern)
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category), do: from(t in query, where: t.category == ^category)

  defp limit_results(query, nil), do: query
  defp limit_results(query, limit), do: from(t in query, limit: ^limit)

  @doc """
  Gets a credential type by slug.
  """
  def get_credential_type_by_slug(slug) do
    Repo.get_by(CredentialType, slug: slug)
  end

  # ============================================================================
  # Resolution (Runtime)
  # ============================================================================

  @doc """
  Resolves a credential for runtime use.
  This decrypts the credential data and returns it in the `data` virtual field.

  This is a sensitive operation and should only be called by the runtime loop.
  The `environment` argument ensures we pick the right version (though currently
  credential IDs are unique per env, this prepares for future env-agnostic refs).
  """
  def resolve_credential(%Scope{} = scope, credential_id, _environment) do
    case get_credential(scope, credential_id) do
      {:ok, credential} ->
        # Log resolution access
        log_credential_access(credential, scope, :accessed, %{reason: "resolve_runtime"})

        # Touch last_used_at (async/fire-and-forget to avoid blocking)
        if Application.get_env(:imgd, :async_credential_touch, true) do
          Task.start(fn ->
            credential
            |> Credential.touch_changeset()
            |> Repo.update()
          end)
        end

        # Decrypt
        Credential.decrypt(credential)

      error ->
        error
    end
  end

  @doc """
  Masks a credential reference ID.
  Useful for logs to avoid showing full IDs if we treat them as semi-sensitive.
  """
  def mask_credential_ref(credential_ref) when is_binary(credential_ref) do
    len = String.length(credential_ref)

    if len > 8 do
      "#{String.slice(credential_ref, 0, 4)}...#{String.slice(credential_ref, -4, 4)}"
    else
      "***"
    end
  end

  def mask_credential_ref(_), do: "***"

  # ============================================================================
  # OAuth (Dynamic)
  # ============================================================================

  @doc """
  Creates or updates a credential from OAuth tokens and user info.

  This is called after a successful OAuth flow to store the tokens as a credential.
  If a credential with the same ID already exists, it will be updated.

  ## Parameters

  - `scope` - The user's scope
  - `credential` - The Credential being connected (with OAuth config already set)
  - `tokens` - Map with "access_token", "refresh_token", "expires_at", etc.
  - `user_info` - Map with "email", "name", "avatar", "uid", etc.
  """
  def complete_oauth_connection(%Scope{} = scope, %Credential{} = credential, tokens, user_info)
      when is_map(tokens) and is_map(user_info) do
    # Get the existing decrypted data (contains client_id, client_secret)
    {:ok, decrypted} = Credential.decrypt(credential)
    existing_data = decrypted.data || %{}

    # Merge tokens into the existing data
    data =
      existing_data
      |> Map.merge(%{
        "access_token" => tokens["access_token"],
        "refresh_token" => tokens["refresh_token"],
        "token_type" => tokens["token_type"] || "Bearer",
        "scope" => tokens["scope"],
        "expires_at" => tokens["expires_at"]
      })
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    # Calculate expires_at DateTime
    expires_at =
      case tokens["expires_at"] do
        nil -> nil
        ts when is_integer(ts) -> DateTime.from_unix!(ts)
        _ -> nil
      end

    # Build account identifier from user info
    account_identifier = user_info["email"] || user_info["nickname"] || user_info["name"]

    attrs = %{
      status: :connected,
      account_identifier: account_identifier,
      data: data,
      expires_at: expires_at,
      metadata:
        Map.merge(credential.metadata || %{}, %{
          "uid" => user_info["uid"],
          "email" => user_info["email"],
          "name" => user_info["name"],
          "avatar" => user_info["avatar"]
        })
    }

    update_credential(scope, credential, attrs)
  end

  @doc """
  Creates a pending OAuth credential (before OAuth flow completion).

  This creates a credential with the OAuth configuration (client_id, client_secret, etc.)
  but without tokens. The credential will be updated with tokens after the OAuth flow.
  """
  def create_oauth_credential(%Scope{} = scope, attrs) when is_map(attrs) do
    type_slug = to_string(attrs[:oauth_provider_slug] || attrs["oauth_provider_slug"])

    type =
      case get_credential_type_by_slug(type_slug) do
        nil -> get_credential_type_by_slug("oauth2")
        found -> found
      end

    if is_nil(type) do
      {:error, :oauth2_type_missing}
    else
      # Data contains client_id and client_secret
      data = %{
        "client_id" => attrs[:client_id] || attrs["client_id"],
        "client_secret" => attrs[:client_secret] || attrs["client_secret"]
      }

      credential_attrs =
        attrs
        |> Map.put(:credential_type_id, type.id)
        |> Map.put(:data, data)
        |> Map.put(:status, :needs_reconnect)

      create_credential(scope, credential_attrs)
    end
  end

  @doc """
  Refreshes an OAuth token if a refresh token is present.
  Uses the credential's embedded OAuth configuration for the refresh request.

  Returns {:ok, updated_credential} or error.
  """
  def refresh_oauth_token(%Credential{} = credential) do
    if Credential.oauth_credential?(credential) do
      do_refresh_oauth_token(credential)
    else
      {:error, :not_oauth_credential}
    end
  end

  defp do_refresh_oauth_token(credential) do
    with {:ok, decrypted} <- Credential.decrypt(credential) do
      data = decrypted.data
      refresh_token = data["refresh_token"]

      if refresh_token do
        case DynamicOAuth.refresh_token(credential, refresh_token) do
          {:ok, new_tokens} ->
            updated_data = Map.merge(data, new_tokens)

            expires_at =
              case new_tokens["expires_at"] do
                nil -> nil
                ts when is_integer(ts) -> DateTime.from_unix!(ts)
                _ -> nil
              end

            scope = %Scope{user: %{id: credential.user_id}}

            update_credential(scope, credential, %{
              data: updated_data,
              status: :connected,
              expires_at: expires_at
            })

          {:error, reason} ->
            # Mark credential as needing reconnect
            scope = %Scope{user: %{id: credential.user_id}}

            update_credential(scope, credential, %{status: :needs_reconnect})
            {:error, {:oauth_refresh_failed, reason}}
        end
      else
        {:error, :no_refresh_token}
      end
    end
  end

  # ============================================================================
  # Audit Logging
  # ============================================================================

  @doc """
  Logs a credential operation.
  """
  def log_credential_access(credential, scope, action, metadata \\ %{}) do
    # This should be robust and not crash the caller
    cur_user = scope && scope.user

    try do
      AuditLog.build(credential, cur_user, action, metadata: metadata)
      |> Repo.insert()
    rescue
      # In critical paths (like resolution), we don't want audit logging failure
      # to stop the workflow. But for high security, maybe we DO want to fail?
      # Decision: Log error but proceed for availability, monitor audit failures.
      e ->
        require Logger
        Logger.error("Failed to write credential audit log: #{inspect(e)}")
        :ok
    end
  end
end
