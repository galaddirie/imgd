defmodule Imgd.Workflows.Workflow do
  @moduledoc """
  Workflow definition schema.

  Stores the design-time workflow configuration including
  nodes, connections, and trigger configuration.

  This is the mutable "draft" state. When published, an immutable
  `WorkflowVersion` snapshot is created.

  ## Pinned Outputs

  The `pinned_outputs` field stores development-time node output pins.
  These are NOT included in published versions - they're iterative
  development tools, not production artifacts.

  Structure: `%{node_id => %{data: ..., pinned_at: ..., ...}}`
  """
  use Imgd.Schema

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Workflows.Embeds.{Node, Connection, Trigger}
  alias Imgd.Executions.Execution
  alias Imgd.Accounts.User

  @type status :: :draft | :active | :archived
  @type trigger_type :: :manual | :webhook | :schedule | :event

  @typedoc "Runtime configuration applied to workflow executions"
  @type settings :: %{
          optional(:timeout_ms) => pos_integer(),
          optional(:max_retries) => non_neg_integer(),
          optional(atom() | String.t()) => any()
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          description: String.t() | nil,
          status: status(),
          nodes: [Node.t()],
          connections: [Connection.t()],
          triggers: [Trigger.t()],
          settings: settings(),
          current_version_tag: String.t() | nil,
          published_version_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :nodes,
             :connections,
             :triggers,
             :settings,
             :status,
             :current_version_tag,
             :published_version_id,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:draft, :active, :archived], default: :draft

    embeds_many :nodes, Node, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete
    embeds_many :triggers, Trigger, on_replace: :delete

    field :settings, :map,
      default: %{
        timeout_ms: 300_000,
        max_retries: 3
      }

    # What you're calling the current draft version (e.g., "1.3.0-dev", "next")
    field :current_version_tag, :string

    # Pointer to currently published immutable version
    belongs_to :published_version, WorkflowVersion

    has_many :versions, WorkflowVersion
    has_many :snapshots, Imgd.Workflows.WorkflowSnapshot
    has_many :editing_sessions, Imgd.Workflows.EditingSession
    has_many :executions, Execution

    belongs_to :user, User

    timestamps()
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :current_version_tag,
      :published_version_id,
      :user_id,
      :settings
    ])
    |> cast_embed(:nodes)
    |> cast_embed(:connections)
    |> cast_embed(:triggers)
    |> validate_required([:name, :user_id, :status])
    |> validate_length(:name, max: 200)
    |> validate_settings()
  end

  defp validate_settings(changeset) do
    validate_change(changeset, :settings, fn :settings, settings ->
      cond do
        not is_map(settings) ->
          [settings: "must be a map"]

        not valid_timeout?(settings) ->
          [settings: "timeout_ms must be a positive integer"]

        not valid_retries?(settings) ->
          [settings: "max_retries must be a non-negative integer"]

        true ->
          []
      end
    end)
  end

  defp valid_timeout?(settings) do
    case fetch_setting(settings, :timeout_ms) do
      nil -> true
      value when is_integer(value) and value > 0 -> true
      _ -> false
    end
  end

  defp valid_retries?(settings) do
    case fetch_setting(settings, :max_retries) do
      nil -> true
      value when is_integer(value) and value >= 0 -> true
      _ -> false
    end
  end

  defp fetch_setting(settings, key) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc "Returns the primary trigger for the workflow, if any."
  def primary_trigger(%__MODULE__{triggers: [trigger | _]}), do: trigger
  def primary_trigger(%__MODULE__{triggers: []}), do: nil

  @doc "Checks if the workflow has a specific trigger type."
  def has_trigger_type?(%__MODULE__{triggers: triggers}, type) do
    Enum.any?(triggers, &(&1.type == type))
  end
end
