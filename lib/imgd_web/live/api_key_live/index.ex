defmodule ImgdWeb.ApiKeyLive.Index do
  use ImgdWeb, :live_view

  alias Imgd.Accounts
  alias Imgd.Accounts.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    api_keys = Accounts.list_api_keys(user)

    {:ok,
     socket
     |> assign(:api_keys, api_keys)
     |> assign(:page_title, "API Keys")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:api_key, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:api_key, %ApiKey{})
  end

  @impl true
  def handle_info({ImgdWeb.ApiKeyLive.CreateApiKeyComponent, {:saved, api_keys}}, socket) do
    {:noreply, assign(socket, :api_keys, api_keys)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    {:ok, _} = Accounts.delete_api_key(user, id)
    api_keys = Accounts.list_api_keys(user)

    {:noreply,
     socket
     |> assign(:api_keys, api_keys)
     |> put_flash(:info, "API key revoked successfully")}
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
                <h1 class="text-3xl font-semibold tracking-tight text-base-content">API Keys</h1>
              </div>
              <p class="max-w-2xl text-sm text-muted">
                Manage your API keys to access the imgd API.
              </p>
            </div>

            <div class="flex gap-3">
              <.link patch={~p"/users/settings/api-keys/new"}>
                <button
                  type="button"
                  class="btn btn-sm btn-primary gap-2"
                >
                  <.icon name="hero-plus" class="size-5" />
                  <span>New API Key</span>
                </button>
              </.link>
            </div>
          </div>
        </div>
      </:page_header>

      <.table id="api-keys" rows={@api_keys} row_click={nil}>
        <:col :let={api_key} label="Name">{api_key.name}</:col>
        <:col :let={api_key} label="Preview">
          <code class="bg-base-200 p-1 rounded font-mono text-xs">{api_key.partial_key}</code>
        </:col>
        <:col :let={api_key} label="Expires At">{render_expiry(api_key.expires_at)}</:col>
        <:col :let={api_key} label="Last Used At">{render_last_used(api_key.last_used_at)}</:col>
        <:col :let={api_key} label="Created At">
          {Calendar.strftime(api_key.inserted_at, "%Y-%m-%d")}
        </:col>
        <:action :let={api_key}>
          <.link
            phx-click={
              JS.push("delete", value: %{id: api_key.id}) |> JS.hide(to: "#api-keys-#{api_key.id}")
            }
            data-confirm="Are you sure you want to revoke this API key?"
            class="text-error hover:opacity-70 font-medium text-sm"
          >
            Revoke
          </.link>
        </:action>
      </.table>

      <.modal
        :if={@live_action == :new}
        id="api-key-modal"
        show
        on_cancel={JS.patch(~p"/users/settings/api-keys")}
      >
        <.live_component
          module={ImgdWeb.ApiKeyLive.CreateApiKeyComponent}
          id={:new}
          title={@page_title}
          action={@live_action}
          api_key={@api_key}
          current_scope={@current_scope}
          patch={~p"/users/settings/api-keys"}
        />
      </.modal>
    </Layouts.app>
    """
  end

  defp render_expiry(nil), do: "Never"
  defp render_expiry(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp render_last_used(nil), do: "Never"
  defp render_last_used(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
