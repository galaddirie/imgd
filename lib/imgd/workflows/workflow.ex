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
  @derive {Jason.Encoder,
           except: [
             :__meta__,
             :published_version,
             :versions,
             :executions,
             :user
           ]}
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

  @typedoc "Pinned output structure"
  @type pinned_output :: %{
          required(:data) => map() | any(),
          required(:pinned_at) => String.t(),
          required(:pinned_by) => String.t(),
          required(:config_hash) => String.t(),
          optional(:source_execution_id) => String.t() | nil,
          optional(:label) => String.t() | nil
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
          pinned_outputs: %{String.t() => pinned_output()},
          current_version_tag: String.t() | nil,
          published_version_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

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

    # Development-time pinned node outputs
    # Structure: %{node_id => %{data: ..., pinned_at: ..., pinned_by: ..., config_hash: ..., ...}}
    field :pinned_outputs, :map, default: %{}

    # What you're calling the current draft version (e.g., "1.3.0-dev", "next")
    field :current_version_tag, :string

    # Pointer to currently published immutable version
    belongs_to :published_version, WorkflowVersion

    has_many :versions, WorkflowVersion
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
      :settings,
      :pinned_outputs
    ])
    |> cast_embed(:nodes)
    |> cast_embed(:connections)
    |> cast_embed(:triggers)
    |> validate_required([:name, :user_id, :status])
    |> validate_length(:name, max: 200)
    |> validate_settings()
    |> validate_pinned_outputs()
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

  defp validate_pinned_outputs(changeset) do
    validate_change(changeset, :pinned_outputs, fn :pinned_outputs, outputs ->
      cond do
        not is_map(outputs) ->
          [pinned_outputs: "must be a map"]

        not Enum.all?(outputs, &valid_pinned_output?/1) ->
          [pinned_outputs: "contains invalid pin data"]

        true ->
          []
      end
    end)
  end

  defp valid_pinned_output?({node_id, pin}) when is_binary(node_id) and is_map(pin) do
    has_data = Map.has_key?(pin, "data") or Map.has_key?(pin, :data)
    has_hash = Map.has_key?(pin, "config_hash") or Map.has_key?(pin, :config_hash)
    has_data and has_hash
  end

  defp valid_pinned_output?(_), do: false

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

  @doc "Returns pinned output data for a node, or nil if not pinned."
  def get_pinned_output(%__MODULE__{pinned_outputs: pins}, node_id) do
    case Map.get(pins || %{}, node_id) do
      nil -> nil
      pin -> Map.get(pin, "data") || Map.get(pin, :data)
    end
  end

  @doc "Checks if a node has pinned output."
  def node_pinned?(%__MODULE__{pinned_outputs: pins}, node_id) do
    Map.has_key?(pins || %{}, node_id)
  end

  @doc "Returns all pinned node IDs."
  def pinned_node_ids(%__MODULE__{pinned_outputs: pins}) do
    Map.keys(pins || %{})
  end

  @doc "Returns the count of pinned nodes."
  def pinned_count(%__MODULE__{pinned_outputs: pins}) do
    map_size(pins || %{})
  end
end
