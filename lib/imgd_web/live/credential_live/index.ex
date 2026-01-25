defmodule ImgdWeb.CredentialLive.Index do
  use ImgdWeb, :live_view

  alias Imgd.Credentials
  alias Imgd.Credentials.Credential

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    credentials = Credentials.list_credentials(scope)
    credential_types = Credentials.list_credential_types()

    {:ok,
     socket
     |> assign(:credentials, credentials)
     |> assign(:credential_types, credential_types)
     |> assign(:page_title, "Credentials")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :credential, nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, :credential, %Credential{})
  end

  @impl true
  def handle_info(
        {ImgdWeb.CredentialLive.CreateCredentialComponent, {:saved, credentials}},
        socket
      ) do
    {:noreply, assign(socket, :credentials, credentials)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Credentials.get_credential(scope, id) do
      {:ok, credential} ->
        case Credentials.delete_credential(scope, credential) do
          {:ok, _} ->
            credentials = Credentials.list_credentials(scope)

            {:noreply,
             socket
             |> assign(:credentials, credentials)
             |> put_flash(:info, "Credential deleted successfully")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete credential")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Credential not found")}
    end
  end

  def handle_event("reconnect", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Credentials.get_credential(scope, id) do
      {:ok, credential} ->
        if Credential.oauth_credential?(credential) do
          {:noreply, redirect(socket, to: ~p"/auth/credentials/#{credential.id}/connect")}
        else
          {:noreply, put_flash(socket, :error, "Credential is not an OAuth credential")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Credential not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:page_header>
        <div class="w-full space-y-6">
          <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div class="space-y-3">
              <p class="text-xs font-semibold uppercase tracking-[0.3em] text-muted">Settings</p>
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">Credentials</h1>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                Manage your API keys, OAuth connections, and other secrets for use in workflows.
              </p>
            </div>

            <div class="flex gap-3">
              <.link patch={~p"/users/settings/credentials/new"}>
                <button type="button" class="btn btn-sm btn-primary gap-2">
                  <.icon name="hero-plus" class="size-5" />
                  <span>New Credential</span>
                </button>
              </.link>
            </div>
          </div>
        </div>
      </:page_header>

      <div class="space-y-8">
        <section>
          <%= if Enum.empty?(@credentials) do %>
            <div class="flex flex-col items-center justify-center py-16 text-center">
              <div class="rounded-full bg-base-200 p-4 mb-4">
                <.icon name="hero-key" class="size-8 text-muted" />
              </div>
              <h3 class="text-lg font-medium text-base-content mb-2">No credentials yet</h3>
              <p class="text-sm text-muted mb-6 max-w-sm">
                Add API keys, OAuth connections, or other secrets to use in your workflows.
              </p>
              <.link patch={~p"/users/settings/credentials/new"}>
                <button type="button" class="btn btn-primary gap-2">
                  <.icon name="hero-plus" class="size-5" />
                  <span>Add Your First Credential</span>
                </button>
              </.link>
            </div>
          <% else %>
            <.table id="credentials" rows={@credentials} row_click={nil}>
              <:col :let={credential} label="Name">
                <div class="flex items-center gap-2">
                  <.icon name={get_type_icon(credential)} class="size-5 text-muted" />
                  <div>
                    <span class="font-medium">{credential.name}</span>
                    <%= if credential.account_identifier do %>
                      <p class="text-xs text-muted">{credential.account_identifier}</p>
                    <% end %>
                  </div>
                </div>
              </:col>
              <:col :let={credential} label="Type">
                <span class="badge badge-ghost badge-sm">
                  {get_type_name(credential)}
                </span>
              </:col>
              <:col :let={credential} label="Status">
                <span class={[
                  "badge badge-sm",
                  credential.status == :connected && "badge-success",
                  credential.status == :needs_reconnect && "badge-warning",
                  credential.status == :expired && "badge-error",
                  credential.status == :error && "badge-error"
                ]}>
                  {format_status(credential.status)}
                </span>
              </:col>
              <:col :let={credential} label="Last Used">
                {render_last_used(credential.last_used_at)}
              </:col>
              <:action :let={credential}>
                <%= if credential.status == :needs_reconnect && Credential.oauth_credential?(credential) do %>
                  <.link
                    phx-click={JS.push("reconnect", value: %{id: credential.id})}
                    class="text-primary hover:opacity-70 font-medium text-sm mr-3"
                  >
                    Reconnect
                  </.link>
                <% end %>
                <.link
                  phx-click={
                    JS.push("delete", value: %{id: credential.id})
                    |> JS.hide(to: "#credentials-#{credential.id}")
                  }
                  data-confirm="Are you sure you want to delete this credential? This action cannot be undone."
                  class="text-error hover:opacity-70 font-medium text-sm"
                >
                  Delete
                </.link>
              </:action>
            </.table>
          <% end %>
        </section>
      </div>

      <.modal
        :if={@live_action == :new}
        id="credential-modal"
        show
        on_cancel={JS.patch(~p"/users/settings/credentials")}
      >
        <.live_component
          module={ImgdWeb.CredentialLive.CreateCredentialComponent}
          id={:new}
          title="New Credential"
          action={@live_action}
          credential={@credential}
          credential_types={@credential_types}
          current_scope={@current_scope}
          patch={~p"/users/settings/credentials"}
        />
      </.modal>
    </Layouts.app>
    """
  end

  defp get_type_icon(credential) do
    case credential.type do
      %{icon: icon} when is_binary(icon) -> icon
      _ -> "hero-key"
    end
  end

  defp get_type_name(credential) do
    case credential.type do
      %{name: name} when is_binary(name) -> name
      _ -> "Unknown"
    end
  end

  defp render_last_used(nil), do: "Never"
  defp render_last_used(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_status(:connected), do: "Connected"
  defp format_status(:needs_reconnect), do: "Needs Reconnect"
  defp format_status(:expired), do: "Expired"
  defp format_status(:error), do: "Error"
  defp format_status(status), do: to_string(status)
end
