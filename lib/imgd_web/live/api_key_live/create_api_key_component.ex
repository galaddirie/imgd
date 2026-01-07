defmodule ImgdWeb.ApiKeyLive.CreateApiKeyComponent do
  use ImgdWeb, :live_component

  alias Imgd.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Create a new API key for your account.</:subtitle>
      </.header>

      <%= if @raw_token do %>
        <div class="mt-8 space-y-4">
          <div class="alert alert-warning">
            <strong>Important:</strong> Copy your API key now. You won't be able to see it again.
          </div>
          <div class="flex items-center gap-2 p-3 bg-base-100 text-base-content rounded-md overflow-x-auto font-mono text-sm group relative">
            <span id="raw-token-display">{@raw_token}</span>
            <button
              id="inline-copy-btn"
              phx-hook=".CopyToClipboard"
              data-text={@raw_token}
              class="ml-auto opacity-0 group-hover:opacity-100 transition-opacity p-1 hover:bg-base-200 rounded text-muted"
              title="Copy to clipboard"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path d="M8 3a1 1 0 011-1h2a1 1 0 110 2H9a1 1 0 01-1-1z" />
                <path d="M6 3a2 2 0 00-2 2v11a2 2 0 002 2h8a2 2 0 002-2V5a2 2 0 00-2-2 3 3 0 01-3 3H9a3 3 0 01-3-3z" />
              </svg>
            </button>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  const text = this.el.dataset.text;
                  navigator.clipboard.writeText(text).then(() => {
                    // Optional: Show a brief success indication
                    const originalTitle = this.el.title;
                    this.el.title = "Copied!";
                    setTimeout(() => {
                      this.el.title = originalTitle;
                    }, 1000);
                  }).catch(err => {
                    console.error('Failed to copy text: ', err);
                  });
                });
              }
            }
          </script>
          <div class="mt-6 flex justify-end gap-3">
            <.button phx-click={JS.patch(@patch)}>Close</.button>
            <.button
              id="main-copy-btn"
              variant="primary"
              phx-hook=".CopyToClipboard"
              data-text={@raw_token}
              type="button"
            >
              Copy API Key
            </.button>
          </div>
        </div>
      <% else %>
        <.simple_form
          for={@form}
          id="api-key-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            placeholder="e.g. Production Mobile App"
            required
          />
          <.input field={@form[:expires_at]} type="datetime-local" label="Expiry (Optional)" />

          <:actions>
            <.button variant="primary" phx-disable-with="Creating...">Create API Key</.button>
          </:actions>
        </.simple_form>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(%{api_key: api_key} = assigns, socket) do
    changeset = Accounts.ApiKey.changeset(api_key, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:raw_token, nil)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"api_key" => api_key_params}, socket) do
    changeset =
      socket.assigns.api_key
      |> Accounts.ApiKey.changeset(api_key_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"api_key" => api_key_params}, socket) do
    save_api_key(socket, api_key_params)
  end

  defp save_api_key(socket, api_key_params) do
    user = socket.assigns.current_scope.user

    case Accounts.create_api_key(user, api_key_params) do
      {:ok, {_api_key, raw_token}} ->
        # Refresh the list in the parent LiveView
        send(self(), {__MODULE__, {:saved, Accounts.list_api_keys(user)}})

        {:noreply,
         socket
         |> assign(:raw_token, raw_token)
         |> put_flash(:info, "API key created successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
