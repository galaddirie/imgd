defmodule Imgd.Workflows.EditingSessions do
  @moduledoc """
  Manages user editing sessions and their associated pins.
  """
  import Ecto.Query, warn: false
  import Imgd.ContextHelpers, only: [scope_user_id!: 1]
  alias Imgd.Repo
  alias Imgd.Accounts.Scope
  alias Imgd.Workflows.{Workflow, WorkflowDraft, EditingSession, PinnedOutput}
  alias Imgd.Workflows.EditingSession.{Registry, DynamicSupervisor, Server}

  # 7 days
  @session_ttl_hours 168

  def get_or_start_session(%Scope{} = scope, %Workflow{} = workflow) do
    user_id = scope_user_id!(scope)
    workflow_id = workflow.id

    case Registry.lookup(user_id, workflow_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_session(scope, workflow) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  def get_or_create_session(%Scope{} = scope, %Workflow{} = workflow) do
    case get_active_session(scope, workflow) do
      nil ->
        create_session(scope, workflow)

      session ->
        touch_session_id(session.id)
        {:ok, session}
    end
  end

  def get_active_session(%Scope{} = scope, %Workflow{} = workflow) do
    user_id = scope_user_id!(scope)

    EditingSession
    |> where([s], s.workflow_id == ^workflow.id)
    |> where([s], s.user_id == ^user_id)
    |> where([s], s.status == :active)
    |> Repo.one()
  end

  def create_session(%Scope{} = scope, %Workflow{} = workflow) do
    user_id = scope_user_id!(scope)

    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{}

    source_hash =
      Imgd.Workflows.compute_source_hash_from_attrs(
        draft.nodes || [],
        draft.connections || [],
        draft.triggers || []
      )

    %EditingSession{}
    |> EditingSession.changeset(%{
      workflow_id: workflow.id,
      user_id: user_id,
      base_source_hash: source_hash,
      status: :active,
      last_activity_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_hours, :hour)
    })
    |> Repo.insert()
  end

  def touch_session_id(session_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    EditingSession
    |> where([s], s.id == ^session_id)
    |> Repo.update_all(
      set: [
        last_activity_at: now,
        expires_at: DateTime.add(now, @session_ttl_hours, :hour)
      ]
    )
  end

  def close_session(%EditingSession{} = session) do
    session
    |> EditingSession.changeset(%{status: :closed})
    |> Repo.update()
  end

  # Pin management

  def list_pins(%EditingSession{} = session, opts \\ []) do
    PinnedOutput
    |> where([p], p.editing_session_id == ^session.id)
    |> maybe_filter_compatible(opts)
    |> Repo.all()
  end

  def list_pins_for_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    user_id = scope_user_id!(scope)

    PinnedOutput
    |> join(:inner, [p], d in assoc(p, :workflow_draft))
    |> where([p, d], d.workflow_id == ^workflow.id)
    |> where([p, _d], p.user_id == ^user_id)
    |> Repo.all()
  end

  def get_compatible_pins(%EditingSession{} = session, source_hash) do
    PinnedOutput
    |> where([p], p.editing_session_id == ^session.id)
    |> where([p], p.source_hash == ^source_hash)
    |> Repo.all()
    |> Map.new(&{&1.node_id, &1.data})
  end

  def create_pin(%EditingSession{} = session, %Scope{} = scope, attrs) do
    user_id = scope_user_id!(scope)

    workflow = Repo.preload(session.workflow, :draft)
    draft = workflow.draft

    attrs =
      Map.merge(attrs, %{
        editing_session_id: session.id,
        user_id: user_id,
        workflow_draft_id: draft.workflow_id,
        pinned_at: DateTime.utc_now()
      })

    %PinnedOutput{}
    |> PinnedOutput.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :data,
           :source_hash,
           :node_config_hash,
           :source_execution_id,
           :label,
           :pinned_at,
           :updated_at
         ]},
      conflict_target: [:editing_session_id, :node_id]
    )
  end

  def delete_pin(%Scope{} = scope, pin_id) do
    user_id = scope_user_id!(scope)

    PinnedOutput
    |> where([p], p.id == ^pin_id)
    |> where([p], p.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Retrieves pins for a session with status metadata (stale, orphaned).
  """
  def get_pins_with_status_from_server(pid, %Workflow{} = workflow) do
    Server.get_status(pid, workflow)
  end

  def build_pins_status(pinned_outputs, base_source_hash, %Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :draft)
    draft = workflow.draft || %WorkflowDraft{}
    nodes_by_id = Map.new(draft.nodes || [], &{&1.id, &1})

    pinned_outputs
    |> Map.new(fn {node_id, pin} ->
      node = Map.get(nodes_by_id, node_id)

      status = %{
        "id" => pin.id,
        "node_id" => node_id,
        "label" => pin.label,
        "pinned_at" => pin.pinned_at,
        "data" => pin.data,
        "node_exists" => not is_nil(node),
        "stale" =>
          is_nil(node) or pin.node_config_hash != Imgd.Workflows.compute_node_config_hash(node),
        "source_hash_match" => pin.source_hash == base_source_hash
      }

      {node_id, status}
    end)
  end

  def clear_pins(%EditingSession{} = session) do
    PinnedOutput
    |> where([p], p.editing_session_id == ^session.id)
    |> Repo.delete_all()
  end

  def cleanup_expired do
    EditingSession
    |> where([s], not is_nil(s.expires_at))
    |> where([s], s.expires_at < ^DateTime.utc_now())
    |> Repo.delete_all()
  end

  defp maybe_filter_compatible(query, opts) do
    case Keyword.get(opts, :compatible_with) do
      nil -> query
      source_hash -> where(query, [p], p.source_hash == ^source_hash)
    end
  end
end
