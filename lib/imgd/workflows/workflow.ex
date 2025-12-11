defmodule Imgd.Workflows.Workflow do
  @moduledoc """
  Workflow definition schema.

  Stores the design-time workflow configuration including
  the serialized Runic build log and trigger configuration.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :status,
             :nodes,
             :connections,
             :triggers,
             :trigger_config,
             :current_version_tag,
             :version,
             :published_version_id,
             :definition,
             :settings,
             :user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema

  alias Imgd.Workflows.WorkflowVersion
  alias Imgd.Executions.Execution
  alias Imgd.Accounts.User

  # Embedded schema modules
  defmodule Node do
    use Ecto.Schema
    @primary_key false

    embedded_schema do
      field :id, :string
      field :type_id, :string
      field :name, :string
      field :config, :map, default: %{}
      field :position, :map, default: %{}
      field :notes, :string
    end
  end

  defmodule Connection do
    use Ecto.Schema
    @primary_key false

    embedded_schema do
      field :id, :string
      field :target_node_id, :string
      field :target_input, :string, default: "main"
      field :source_node_id, :string
      field :source_output, :string, default: "main"
    end
  end

  defmodule Trigger do
    use Ecto.Schema
    @primary_key false

    embedded_schema do
      field :type, Ecto.Enum, values: [:manual, :webhook, :schedule, :event]
      field :config, :map, default: %{}
    end
  end

  @type status :: :draft | :active | :archived
  @type trigger_type :: :manual | :webhook | :schedule | :event

  @typedoc "Embedded workflow node definition"
  @type workflow_node :: %Node{
          id: String.t(),
          type_id: String.t(),
          name: String.t(),
          config: map(),
          position: map(),
          notes: String.t() | nil
        }

  @typedoc "Edge between workflow nodes"
  @type connection :: %Connection{
          id: String.t(),
          source_node_id: String.t(),
          source_output: String.t(),
          target_node_id: String.t(),
          target_input: String.t()
        }

  @typedoc "Trigger definition used to start workflow executions"
  @type trigger :: %Trigger{type: trigger_type(), config: map()}

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
          nodes: [workflow_node()],
          connections: [connection()],
          triggers: [trigger()],
          trigger_config: map() | nil,
          settings: settings(),
          version: String.t() | nil,
          definition: map() | nil,
          current_version_tag: String.t() | nil,
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

    # Virtual fields used by the UI
    field :trigger_config, :map, virtual: true
    field :version, :string, virtual: true
    field :definition, :map, virtual: true

    # Runtime settings
    field :settings, :map,
      default: %{
        timeout_ms: 300_000,
        max_retries: 3
      }

    # Optional: what you're *calling* the current draft version.
    # Could be "1.3.0-dev", "next", etc.
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
    |> cast(
      attrs,
      [
        :name,
        :description,
        :status,
        :current_version_tag,
        :published_version_id,
        :user_id,
        :settings
      ],
      empty_values: []
    )
    |> cast_embed(:nodes, with: &node_changeset/2)
    |> cast_embed(:connections, with: &connection_changeset/2)
    |> cast_embed(:triggers, with: &trigger_changeset/2)
    |> validate_required([:name, :user_id, :status])
    |> validate_length(:name, max: 200)
    |> validate_settings()
  end

  defp node_changeset(node, attrs) do
    node
    |> cast(attrs, [:id, :type_id, :name, :config, :position, :notes])
    |> validate_required([:id, :type_id, :name])
  end

  defp connection_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:id, :source_node_id, :source_output, :target_node_id, :target_input])
    |> validate_required([:id, :source_node_id, :target_node_id])
  end

  defp trigger_changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :config])
    |> validate_required([:type])
  end

  defp validate_settings(changeset) do
    validate_change(changeset, :settings, fn :settings, settings ->
      with true <- is_map(settings),
           :ok <- validate_positive_integer(settings, :timeout_ms),
           :ok <- validate_non_negative_integer(settings, :max_retries) do
        []
      else
        false -> [settings: "must be a map"]
        {:error, message} -> [settings: message]
      end
    end)
  end

  defp validate_positive_integer(settings, key) do
    case fetch_setting(settings, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp validate_non_negative_integer(settings, key) do
    case fetch_setting(settings, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _ -> {:error, "#{key} must be a non-negative integer"}
    end
  end

  defp fetch_setting(settings, key) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end
end
