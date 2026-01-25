defmodule Imgd.Credentials.Registry do
  @moduledoc """
  In-memory registry for credential types.

  Credential types are defined as code and loaded at startup.
  """
  use GenServer
  require Logger
  alias Imgd.Credentials.Type

  @ets_table :imgd_credential_types

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all registered credential types.
  """
  @spec all() :: [Type.t()]
  def all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, type} -> type end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets a credential type by slug.
  """
  @spec get(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case :ets.lookup(@ets_table, id) do
      [{^id, type}] -> {:ok, type}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets a credential type by slug or raises.
  """
  @spec get!(String.t()) :: Type.t()
  def get!(id) do
    case get(id) do
      {:ok, type} -> type
      {:error, :not_found} -> raise "Credential type not found: #{id}"
    end
  end

  @doc """
  Lists credential types by category.
  """
  @spec list_by_category(String.t()) :: [Type.t()]
  def list_by_category(category) when is_binary(category) do
    all()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Returns a list of all unique categories.
  """
  @spec categories() :: [String.t()]
  def categories do
    all()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    types = discover_types()

    for type <- types do
      :ets.insert(@ets_table, {type.id, type})
    end

    Logger.info("Credential Registry initialized with #{length(types)} types")

    {:ok, %{}}
  end

  defp discover_types do
    builtin_modules()
    |> Enum.map(& &1.definition())
  end

  defp builtin_modules do
    [
      Imgd.Credentials.Types.ApiKey,
      Imgd.Credentials.Types.BearerToken,
      Imgd.Credentials.Types.BasicAuth,
      Imgd.Credentials.Types.OAuth2,
      Imgd.Credentials.Types.OpenAI,
      Imgd.Credentials.Types.Anthropic,
      Imgd.Credentials.Types.Custom,
      Imgd.Credentials.Types.GithubOAuth,
      Imgd.Credentials.Types.GithubToken
    ]
  end
end
