defmodule Imgd.Executions.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, inputs, outputs, and error information.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :workflow_version_id,
             :status,
             :trigger,
             :context,
             :error,
             :started_at,
             :completed_at,
             :expires_at,
             :metadata,
             :workflow_id,
             :triggered_by_user_id,
             :inserted_at,
             :updated_at
           ]}
  use Imgd.Schema
  import Ecto.Query

  alias Imgd.Engine.DataFlow
  alias Imgd.Workflows.{Workflow}
  alias Imgd.Accounts.User

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event

  # Todo: add types
  schema "executions" do
    belongs_to :workflow_version, WorkflowVersion

    field :status, Ecto.Enum,
      values: [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout],
      default: :pending

    field :trigger, :map,
      default: %{
        type: :manual,
        data: %{}
      }

    # Runic integration - the event log for rebuilding state
    # ComponentAdded events
    field :runic_build_log, {:array, :map}, default: []
    # ReactionOccurred events
    field :runic_reaction_log, {:array, :map}, default: []

    # Execution context - accumulated outputs from all nodes
    field :context, :map, default: %{}

    # Todo: I hate untyped error maps
    field :error, :map

    # For waiting/paused executions
    field :waiting_for, :map  # {:node_id, :reason, :resume_data}

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    # TTL for long-running cleanup
    field :expires_at, :utc_datetime_usec

    # todo: fix this i hate untyped metadata json fields
    # Metadata for correlation, debugging
    field :metadata, :map, default: %{}
    # Example: %{
    #   trace_id: "...",
    #   correlation_id: "...",
    #   triggered_by: "user_id" | "schedule_id" | "webhook_request_id",
    #   parent_execution_id: "..." (for sub-workflows)
    # }

    belongs_to :workflow, Workflow
    belongs_to :triggered_by_user, User, foreign_key: :triggered_by_user_id
    has_many :node_executions, NodeExecution

    timestamps()
  end

  # TODO: Changesets
end
