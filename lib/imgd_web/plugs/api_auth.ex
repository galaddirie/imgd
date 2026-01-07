defmodule ImgdWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug to authenticate API requests using an API key.

  Expects an `Authorization: Bearer <key>` header.
  If a valid key is provided, it assigns the corresponding `Imgd.Accounts.Scope`
  to the connection.
  """
  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  alias Imgd.Accounts
  alias Imgd.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_bearer_token(conn) do
      {:ok, token} ->
        case Accounts.get_api_key_by_token(token) do
          nil ->
            assign_public_scope(conn)

          api_key ->
            # Update last used timestamp
            update_last_used(api_key)

            conn
            |> assign(:current_scope, Scope.for_user(api_key.user))
        end

      :error ->
        assign_public_scope(conn)
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, token}
      _ -> :error
    end
  end

  defp assign_public_scope(conn) do
    if Map.has_key?(conn.assigns, :current_scope) do
      conn
    else
      assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp update_last_used(api_key) do
    Imgd.Repo.update_all(
      from(k in Imgd.Accounts.ApiKey, where: k.id == ^api_key.id),
      set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end
end
