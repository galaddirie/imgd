defmodule Imgd.Workflows.WorkflowVersion do
  @moduledoc """
  Immutable workflow version snapshot.

  Created each time a workflow is published, preserving the exact
  definition for audit trails and execution reproducibility.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Imgd.Workflows.Workflow
  alias Imgd.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflow_versions" do
    field :version, :integer
    field :definition, :map
    field :definition_hash, :integer
    field :change_summary, :string

    belongs_to :published_by_user, User, foreign_key: :published_by, type: :id

    belongs_to :workflow, Workflow

    # Immutable - no updates
    timestamps(updated_at: false)
  end

  @required_fields [:version, :definition, :workflow_id]
  @optional_fields [:change_summary, :published_by, :definition_hash]

  def changeset(version, attrs) do
    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> compute_definition_hash()
    |> unique_constraint([:workflow_id, :version])
    |> foreign_key_constraint(:workflow_id)
  end

  # Queries

  def by_workflow(query \\ __MODULE__, workflow_id) do
    from v in query,
      where: v.workflow_id == ^workflow_id,
      order_by: [desc: v.version]
  end

  def latest(query \\ __MODULE__) do
    from v in query,
      order_by: [desc: v.version],
      limit: 1
  end

  def at_version(query \\ __MODULE__, version) do
    from v in query, where: v.version == ^version
  end

  # Helpers

  defp compute_definition_hash(changeset) do
    case get_change(changeset, :definition) do
      nil -> changeset
      definition -> put_change(changeset, :definition_hash, :erlang.phash2(definition))
    end
  end

  @doc """
  Creates a version snapshot from a workflow.
  """
  def from_workflow(%Workflow{} = workflow, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      workflow_id: workflow.id,
      version: workflow.version,
      definition: workflow.definition,
      change_summary: opts[:change_summary],
      published_by: opts[:published_by]
    })
  end
end
