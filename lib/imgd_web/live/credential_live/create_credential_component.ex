defmodule ImgdWeb.CredentialLive.CreateCredentialComponent do
  @moduledoc """
  LiveComponent for creating credentials with a unified wizard flow (like n8n).

  Flow:
  1. Select credential type from a searchable dropdown
  2. Configure the credential (OAuth or API key fields)

  For OAuth credentials, the provider is derived from the credential type slug.
  """
  use ImgdWeb, :live_component

  alias Imgd.Credentials
  alias Imgd.Credentials.OAuthConfig

  @oauth_types ~w(oauth2 google github slack)

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Add a new credential to use in your workflows.</:subtitle>
      </.header>

      <%= if @selected_type == nil do %>
        <.render_type_selector
          credential_types={@credential_types}
          search_query={@search_query}
          filtered_types={@filtered_types}
          myself={@myself}
        />
      <% else %>
        <%= if is_oauth_type?(@selected_type.id) do %>
          <.render_oauth_config
            form={@form}
            selected_type={@selected_type}
            callback_url={@callback_url}
            myself={@myself}
          />
        <% else %>
          <.render_form_fields
            form={@form}
            selected_type={@selected_type}
            myself={@myself}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_type_selector(assigns) do
    ~H"""
    <div class="mt-6 space-y-4">
      <div class="relative">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="absolute left-3 top-1/2 -translate-y-1/2 size-5 text-muted pointer-events-none"
          />
          <input
            type="text"
            id="credential-type-search"
            value={@search_query}
            phx-keyup="search"
            phx-target={@myself}
            phx-debounce="150"
            placeholder="Search credentials..."
            class="input input-bordered w-full pl-10 pr-4"
            autocomplete="off"
          />
        </div>
      </div>

      <div class="max-h-80 overflow-y-auto rounded-lg border border-base-300">
        <%= if Enum.empty?(@filtered_types) do %>
          <div class="p-6 text-center text-muted">
            <.icon name="hero-magnifying-glass" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">No credentials found matching "{@search_query}"</p>
          </div>
        <% else %>
          <div class="divide-y divide-base-300">
            <%= for {category, types} <- Enum.group_by(@filtered_types, & &1.category) |> Enum.sort() do %>
              <div class="bg-base-200/50 px-4 py-2 text-xs font-semibold text-muted uppercase tracking-wider sticky top-0 z-10 backdrop-blur-sm">
                {category}
              </div>
              <%= for type <- types do %>
                <button
                  type="button"
                  phx-click="select_type"
                  phx-value-type-id={type.id}
                  phx-target={@myself}
                  class="w-full flex items-center gap-3 p-3 hover:bg-base-200 transition-colors text-left"
                >
                  <div class="flex-shrink-0 rounded-full bg-base-200 p-2">
                    <.icon name={type.icon || "hero-key"} class="size-5 text-primary" />
                  </div>
                  <div class="flex-1 min-w-0">
                    <p class="font-medium text-base-content truncate">{type.name}</p>
                    <p class="text-xs text-muted truncate">{type.category}</p>
                  </div>
                  <.icon name="hero-chevron-right" class="size-4 text-muted flex-shrink-0" />
                </button>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>

      <p class="text-xs text-muted text-center">
        {length(@filtered_types)} types found
      </p>
    </div>
    """
  end

  defp render_oauth_config(assigns) do
    ~H"""
    <div class="mt-6">
      <div class="flex items-center gap-2 mb-4">
        <button
          type="button"
          phx-click="back_to_select"
          phx-target={@myself}
          class="btn btn-ghost btn-sm gap-1"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back
        </button>
        <div class="flex items-center gap-2">
          <div class="rounded-full bg-base-200 p-1.5">
            <.icon name={@selected_type.icon || "hero-key"} class="size-4 text-primary" />
          </div>
          <span class="text-sm font-medium text-base-content">{@selected_type.name}</span>
        </div>
      </div>

      <div class="mb-4 p-4 rounded-lg bg-base-200 border border-base-300">
        <div class="flex items-start gap-3">
          <.icon name="hero-information-circle" class="size-5 text-info flex-shrink-0 mt-0.5" />
          <div class="space-y-2 flex-1 min-w-0">
            <p class="text-sm font-medium text-base-content">OAuth Redirect URL</p>
            <p class="text-xs text-muted">
              Add this URL to your OAuth app's authorized redirect URIs:
            </p>
            <div class="flex items-center gap-2">
              <code class="text-xs bg-base-300 px-2 py-1 rounded font-mono break-all select-all">
                {@callback_url}
              </code>
              <button
                type="button"
                id="copy-callback-url-btn"
                phx-hook=".CopyToClipboard"
                data-copy-text={@callback_url}
                class="btn btn-ghost btn-xs"
                title="Copy to clipboard"
              >
                <.icon name="hero-clipboard-document" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.dataset.copyText;
              navigator.clipboard.writeText(text).then(() => {
                const icon = this.el.querySelector("span");
                if (icon) {
                  icon.classList.remove("hero-clipboard-document");
                  icon.classList.add("hero-check");
                  setTimeout(() => {
                    icon.classList.remove("hero-check");
                    icon.classList.add("hero-clipboard-document");
                  }, 2000);
                }
              });
            });
          }
        }
      </script>

      <.simple_form
        for={@form}
        id="oauth-credential-form"
        phx-target={@myself}
        phx-change="validate_oauth"
        phx-submit="save_oauth"
        autocomplete="off"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder={"e.g. My #{provider_display_name(@selected_type.id)} Account"}
          required
          autocomplete="off"
        />

        <.input
          field={@form[:client_id]}
          type="text"
          label="Client ID"
          placeholder="Your OAuth client ID"
          autocomplete="off"
          required
        />

        <.input
          field={@form[:client_secret]}
          type="password"
          label="Client Secret"
          placeholder="Your OAuth client secret"
          autocomplete="off"
          required
        />

        <.input
          field={@form[:scopes]}
          type="text"
          label="Scopes"
          placeholder="Space-separated scopes (e.g. email profile)"
          autocomplete="off"
        />

        <div
          class="border-t border-base-300 pt-4 mt-4"
          phx-update="ignore"
          id="advanced-oauth-section-wrapper"
        >
          <details class="group">
            <summary class="cursor-pointer text-sm font-medium text-base-content flex items-center gap-2">
              <.icon
                name="hero-chevron-right"
                class="size-4 transition-transform group-open:rotate-90"
              /> Advanced Settings
            </summary>
            <div class="mt-4 space-y-4 pl-6">
              <.input
                field={@form[:domain_restriction]}
                type="select"
                label="Domain Restriction"
                options={[
                  {"All Domains", "all"},
                  {"Specific Domains", "specific"},
                  {"None (Disabled)", "none"}
                ]}
              />

              <%= if @form[:domain_restriction].value == "specific" do %>
                <.input
                  field={@form[:allowed_domains_pattern]}
                  type="text"
                  label="Allowed Domains Pattern"
                  placeholder="e.g. ^api\\.example\\.com$|^.*\\.mycompany\\.com$"
                  autocomplete="off"
                />
                <p class="text-xs text-muted -mt-2">
                  Enter a regex pattern to match allowed domains.
                </p>
              <% end %>

              <.input
                field={@form[:authorization_url]}
                type="text"
                label="Custom Authorization URL"
                placeholder="Leave blank to use default"
                autocomplete="off"
              />

              <.input
                field={@form[:token_url]}
                type="text"
                label="Custom Token URL"
                placeholder="Leave blank to use default"
                autocomplete="off"
              />
            </div>
          </details>
        </div>

        <:actions>
          <.button variant="primary" phx-disable-with="Connecting...">
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Connect Account
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  defp render_form_fields(assigns) do
    ~H"""
    <div class="mt-6">
      <div class="flex items-center gap-2 mb-4">
        <button
          type="button"
          phx-click="back_to_select"
          phx-target={@myself}
          class="btn btn-ghost btn-sm gap-1"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back
        </button>
        <div class="flex items-center gap-2">
          <div class="rounded-full bg-base-200 p-1.5">
            <.icon name={@selected_type.icon || "hero-key"} class="size-4 text-primary" />
          </div>
          <span class="text-sm font-medium text-base-content">{@selected_type.name}</span>
        </div>
      </div>

      <.simple_form
        for={@form}
        id="credential-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder={"e.g. My #{@selected_type.name}"}
          required
          autocomplete="off"
        />

        <%= for {field_name, field_config} <- get_schema_fields(@selected_type) do %>
          <.input
            field={@form[String.to_atom("data_" <> field_name)]}
            type={field_input_type(field_config)}
            label={field_config["title"] || humanize(field_name)}
            required={field_required?(@selected_type, field_name)}
            autocomplete="off"
          />
        <% end %>

        <div
          class="border-t border-base-300 pt-4 mt-4"
          phx-update="ignore"
          id="advanced-section-wrapper"
        >
          <details class="group">
            <summary class="cursor-pointer text-sm font-medium text-base-content flex items-center gap-2">
              <.icon
                name="hero-chevron-right"
                class="size-4 transition-transform group-open:rotate-90"
              /> Advanced Settings
            </summary>
            <div class="mt-4 space-y-4 pl-6">
              <.input
                field={@form[:domain_restriction]}
                type="select"
                label="Domain Restriction"
                options={[
                  {"All Domains", "all"},
                  {"Specific Domains", "specific"},
                  {"None (Disabled)", "none"}
                ]}
              />

              <%= if @form[:domain_restriction].value == "specific" do %>
                <.input
                  field={@form[:allowed_domains_pattern]}
                  type="text"
                  label="Allowed Domains Pattern"
                  placeholder="e.g. ^api\\.example\\.com$|^.*\\.mycompany\\.com$"
                  autocomplete="off"
                />
                <p class="text-xs text-muted -mt-2">
                  Enter a regex pattern to match allowed domains.
                </p>
              <% end %>
            </div>
          </details>
        </div>

        <:actions>
          <.button variant="primary" phx-disable-with="Creating...">
            Create Credential
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    callback_url = ImgdWeb.Endpoint.url() <> "/auth/credentials/callback"
    credential_types = assigns[:credential_types] || []

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:callback_url, callback_url)
     |> assign_new(:search_query, fn -> "" end)
     |> assign_new(:filtered_types, fn -> credential_types end)
     |> assign_new(:selected_type, fn -> nil end)
     |> assign_new(:form, fn -> to_form(%{}) end)}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    filtered =
      if String.trim(query) == "" do
        Credentials.list_credential_types(limit: 50)
      else
        Credentials.list_credential_types(search: query, limit: 50)
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_types, filtered)}
  end

  def handle_event("select_type", %{"type-id" => type_id}, socket) do
    # Since we are filtering on server, the selected type MUST be in @filtered_types
    selected_type = Enum.find(socket.assigns.filtered_types, &(&1.id == type_id))

    if selected_type do
      if is_oauth_type?(selected_type.id) do
        # OAuth credential - derive provider from type slug
        changeset = build_oauth_changeset(selected_type.id, %{})

        {:noreply,
         socket
         |> assign(:selected_type, selected_type)
         |> assign(:form, to_form(changeset, as: "credential"))}
      else
        # Non-OAuth credential
        changeset = build_changeset(selected_type, %{})

        {:noreply,
         socket
         |> assign(:selected_type, selected_type)
         |> assign(:form, to_form(changeset, as: "credential"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("back_to_select", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_type, nil)
     |> assign(:form, to_form(%{}))}
  end

  def handle_event("validate", %{"credential" => params}, socket) do
    changeset =
      build_changeset(socket.assigns.selected_type, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "credential"))}
  end

  def handle_event("validate_oauth", %{"credential" => params}, socket) do
    changeset =
      build_oauth_changeset(socket.assigns.selected_type.id, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "credential"))}
  end

  def handle_event("save", %{"credential" => params}, socket) do
    scope = socket.assigns.current_scope
    selected_type = socket.assigns.selected_type

    # Extract data fields from params
    data = extract_data_fields(params, selected_type)

    attrs = %{
      name: params["name"],
      domain_restriction: String.to_existing_atom(params["domain_restriction"] || "all"),
      allowed_domains_pattern: params["allowed_domains_pattern"],
      type_id: selected_type.id,
      data: data
    }

    case Credentials.create_credential(scope, attrs) do
      {:ok, _credential} ->
        credentials = Credentials.list_credentials(scope)
        send(self(), {__MODULE__, {:saved, credentials}})

        {:noreply,
         socket
         |> put_flash(:info, "Credential created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "credential"))}
    end
  end

  def handle_event("save_oauth", %{"credential" => params}, socket) do
    scope = socket.assigns.current_scope
    selected_type = socket.assigns.selected_type

    # Parse scopes from space-separated string
    scopes = parse_scopes(params["scopes"])

    # Derive provider slug from credential type
    provider_slug = derive_oauth_provider(selected_type.id)

    attrs = %{
      name: params["name"],
      oauth_provider_slug: provider_slug,
      oauth_scopes: scopes,
      authorization_url: blank_to_nil(params["authorization_url"]),
      token_url: blank_to_nil(params["token_url"]),
      domain_restriction: String.to_existing_atom(params["domain_restriction"] || "all"),
      allowed_domains_pattern: params["allowed_domains_pattern"],
      client_id: params["client_id"],
      client_secret: params["client_secret"],
      type_id: selected_type.id
    }

    case Credentials.create_oauth_credential(scope, attrs) do
      {:ok, credential} ->
        # Redirect to OAuth flow to complete connection
        {:noreply, redirect(socket, to: ~p"/auth/credentials/#{credential.id}/connect")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "credential"))}

      {:error, :oauth2_type_missing} ->
        {:noreply,
         put_flash(socket, :error, "OAuth credential type not configured in the system")}
    end
  end

  # Build a changeset for non-OAuth credentials
  defp build_changeset(selected_type, params) do
    types =
      %{
        name: :string,
        domain_restriction: :string,
        allowed_domains_pattern: :string
      }
      |> Map.merge(data_field_types(selected_type))

    data = %{domain_restriction: "all"}

    {data, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:name])
    |> validate_domain_pattern()
  end

  # Build a changeset for OAuth credentials
  defp build_oauth_changeset(type_id, params) do
    types = %{
      name: :string,
      client_id: :string,
      client_secret: :string,
      scopes: :string,
      authorization_url: :string,
      token_url: :string,
      domain_restriction: :string,
      allowed_domains_pattern: :string
    }

    # Get default scopes for the provider
    provider_slug = derive_oauth_provider(type_id)

    default_scopes =
      provider_slug
      |> OAuthConfig.default_scopes()
      |> Enum.join(" ")

    data = %{
      scopes: default_scopes,
      domain_restriction: "all"
    }

    {data, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:name, :client_id, :client_secret])
    |> validate_domain_pattern()
  end

  defp validate_domain_pattern(changeset) do
    domain_restriction = Ecto.Changeset.get_field(changeset, :domain_restriction)
    pattern = Ecto.Changeset.get_field(changeset, :allowed_domains_pattern)

    cond do
      domain_restriction == "specific" && (is_nil(pattern) || pattern == "") ->
        Ecto.Changeset.add_error(
          changeset,
          :allowed_domains_pattern,
          "is required when using specific domains"
        )

      domain_restriction == "specific" && is_binary(pattern) ->
        case Regex.compile(pattern) do
          {:ok, _} ->
            changeset

          {:error, {reason, _}} ->
            Ecto.Changeset.add_error(
              changeset,
              :allowed_domains_pattern,
              "is not a valid regex: #{reason}"
            )
        end

      true ->
        changeset
    end
  end

  defp data_field_types(selected_type) do
    get_schema_fields(selected_type)
    |> Enum.map(fn {name, _config} ->
      {String.to_atom("data_" <> name), :string}
    end)
    |> Map.new()
  end

  defp extract_data_fields(params, selected_type) do
    get_schema_fields(selected_type)
    |> Enum.map(fn {name, _config} ->
      {name, params["data_" <> name]}
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) || v == "" end)
    |> Map.new()
  end

  defp get_schema_fields(nil), do: []

  defp get_schema_fields(type) do
    case type.field_schema do
      %{"properties" => props} when is_map(props) ->
        Map.to_list(props)

      _ ->
        []
    end
  end

  defp field_input_type(%{"format" => "password"}), do: "password"
  defp field_input_type(_), do: "text"

  defp field_required?(type, field_name) do
    case type.field_schema do
      %{"required" => required} when is_list(required) ->
        field_name in required

      _ ->
        false
    end
  end

  defp humanize(field_name) do
    field_name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp is_oauth_type?(id), do: id in @oauth_types

  # Derive OAuth provider slug from credential type slug
  defp derive_oauth_provider("google"), do: :google
  defp derive_oauth_provider("github"), do: :github
  defp derive_oauth_provider("slack"), do: :slack
  defp derive_oauth_provider("oauth2"), do: :custom
  defp derive_oauth_provider(_), do: :custom

  defp provider_display_name("google"), do: "Google"
  defp provider_display_name("github"), do: "GitHub"
  defp provider_display_name("slack"), do: "Slack"
  defp provider_display_name("oauth2"), do: "OAuth"
  defp provider_display_name(slug), do: String.capitalize(slug)

  defp parse_scopes(nil), do: []
  defp parse_scopes(""), do: []

  defp parse_scopes(scopes_string) when is_binary(scopes_string) do
    scopes_string
    |> String.split(~r/[\s,]+/, trim: true)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
