defmodule ImgdWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ImgdWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :page_header, doc: "content for the page header section"
  slot :inner_block, required: true, doc: "main content below the page header"

  attr :current_path, :string, default: "/"
  attr :hide_nav, :boolean, default: false
  attr :full_bleed, :boolean, default: false

  def app(assigns) do
    ~H"""
    <!-- Overall container with muted background -->
    <div class={[
      "flex min-h-screen flex-col",
      @full_bleed && "bg-base-200",
      !@full_bleed && "bg-base-200/50"
    ]}>
      <!-- Sticky navigation header -->
      <%= if !@hide_nav do %>
        <header class="sticky top-0 z-50 border-b border-base-200 bg-base-100/80 backdrop-blur supports-[backdrop-filter]:bg-base-100/60">
          <div class="navbar mx-auto px-8 ">
            <!-- Mobile: left dropdown -->
            <div class="navbar-start">
              <div class="dropdown">
                <button tabindex="0" class="btn btn-ghost lg:hidden" aria-label="Open menu">
                  <!-- hamburger -->
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-5 w-5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M4 6h16M4 12h16M4 18h16"
                    />
                  </svg>
                </button>
                <ul
                  tabindex="0"
                  class="menu menu-sm dropdown-content mt-3 w-52 rounded-box bg-base-100 p-2 shadow"
                >
                  <li>
                    <a href="/">
                      <.icon name="hero-home" class="size-4" /> Overview
                    </a>
                  </li>
                  <%= if @current_scope do %>
                    <li>
                      <a href="/workflows">
                        <.icon name="hero-squares-2x2" class="size-4" /> Workflows
                      </a>
                    </li>
                  <% end %>
                  <li><hr class="my-1 border-base-300" /></li>
                  <%= if @current_scope do %>
                    <li class="menu-title">
                      <span class="text-sm font-semibold">{@current_scope.user.email}</span>
                    </li>
                    <li>
                      <.link href={~p"/users/settings"}>
                        <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                      </.link>
                    </li>
                    <li>
                      <.link href={~p"/users/log-out"} method="delete">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                      </.link>
                    </li>
                  <% else %>
                    <li>
                      <.link href={~p"/users/log-in"}>
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log in
                      </.link>
                    </li>
                    <li>
                      <.link href={~p"/users/register"}>
                        <.icon name="hero-user-plus" class="size-4" /> Register
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>

              <a href="/" class="btn btn-ghost gap-2 px-2 hover:bg-base-200 transition-colors">
                <img
                  src={~p"/images/logo-v3.svg"}
                  width="28"
                  height="28"
                  alt="Imgd logo"
                  class="dark:invert"
                />
                <span class="font-semibold text-lg">imgd.io</span>
              </a>
            </div>

            <nav class="navbar-end gap-2">
              <ul class="menu menu-horizontal px-1 hidden lg:flex flex-nowrap">
                <li>
                  <a href="/" class="btn btn-ghost gap-2  transition-colors">
                    <.icon name="hero-home" class="size-5" /> Overview
                  </a>
                </li>
                <%= if @current_scope do %>
                  <li>
                    <a href="/workflows" class="btn btn-ghost gap-2  transition-colors">
                      <.icon name="hero-squares-2x2" class="size-5" /> Workflows
                    </a>
                  </li>
                <% end %>
              </ul>
              
    <!-- Auth Navigation -->
              <%= if @current_scope do %>
                <div class="dropdown dropdown-end hidden lg:block">
                  <button
                    tabindex="0"
                    class="btn btn-ghost btn-sm gap-2 hover:bg-base-200 transition-colors"
                    aria-label="User menu"
                  >
                    <div class="avatar avatar-ring avatar-sm">
                      <div class="bg-primary text-primary-content rounded-full w-6 h-6 flex items-center justify-center">
                        <.icon name="hero-user-solid" class="size-3" />
                      </div>
                    </div>
                    <span class="hidden sm:inline text-sm font-medium">
                      {@current_scope.user.email}
                    </span>
                    <.icon name="hero-chevron-down-solid" class="size-4" />
                  </button>
                  <ul
                    tabindex="0"
                    class="menu menu-sm dropdown-content mt-3 w-52 rounded-box bg-base-100 p-2 shadow-lg border border-base-300"
                  >
                    <li>
                      <.link href={~p"/users/settings"} class="gap-2">
                        <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                      </.link>
                    </li>
                    <li>
                      <.link href={~p"/users/log-out"} method="delete" class="gap-2">
                        <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                      </.link>
                    </li>
                  </ul>
                </div>
              <% else %>
                <div class="flex gap-2">
                  <.link
                    href={~p"/users/log-in"}
                    class="btn btn-ghost btn-sm gap-2 hover:bg-base-200 transition-colors"
                  >
                    <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log in
                  </.link>
                  <.link
                    href={~p"/users/register"}
                    class="btn btn-primary btn-sm gap-2 hover:bg-primary-focus transition-colors"
                  >
                    <.icon name="hero-user-plus" class="size-4" /> Register
                  </.link>
                </div>
              <% end %>

              <.theme_toggle />
            </nav>
          </div>
        </header>
      <% end %>

      <main class="flex flex-1 flex-col">
        <div class="flex w-full grow flex-col">
          <div class="flex h-full w-full flex-col items-stretch justify-start">
            <!-- Page Header Section -->
            <%= if @page_header != [] do %>
              <div class="bg-base-100 border-base-200 border-b pt-20">
                <div class={[
                  "flex min-h-[200px] w-full flex-col items-start justify-between",
                  !@full_bleed && "mx-auto max-w-7xl px-8"
                ]}>
                  {render_slot(@page_header)}
                </div>
              </div>
            <% end %>
            
    <!-- Content Area with secondary background -->
            <div class={[
              "flex-1",
              !@full_bleed && "p-6"
            ]}>
              <!-- Flash messages positioned here -->
              <div class={[
                "w-full",
                !@full_bleed && "mx-auto max-w-7xl px-8 pt-6"
              ]}>
                <.flash_group flash={@flash} />
                <div class={[
                  !@full_bleed && "py-6"
                ]}>
                  {render_slot(@inner_block)}
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
