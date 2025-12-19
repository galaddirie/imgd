defmodule Imgd.Workflows.EditingSessions do
  @moduledoc """
  Manages user editing sessions and their associated pins.
  """
  import Ecto.Query, warn: false
  import Imgd.ContextHelpers, only: [scope_user_id!: 1]
  alias Imgd.Repo
  alias Imgd.Accounts.Scope
  alias Imgd.Workflows.{Workflow, EditingSession, PinnedOutput}

  # 7 days
  @session_ttl_hours 168

  def get_or_create_session(%Scope{} = scope, %Workflow{} = workflow) do
    case get_active_session(scope, workflow) do
      nil -> create_session(scope, workflow)
      session -> {:ok, touch_session(session)}
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

    source_hash =
      Imgd.Workflows.WorkflowSnapshot.compute_source_hash(
        workflow.nodes || [],
        workflow.connections || [],
        workflow.triggers || []
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

  def touch_session(%EditingSession{} = session) do
    session
    |> EditingSession.changeset(%{
      last_activity_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_hours, :hour)
    })
    |> Repo.update!()
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
    |> where([p], p.workflow_id == ^workflow.id)
    |> where([p], p.user_id == ^user_id)
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

    attrs =
      Map.merge(attrs, %{
        editing_session_id: session.id,
        user_id: user_id,
        workflow_id: session.workflow_id,
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
  def get_pins_with_status(%EditingSession{} = session, %Workflow{} = workflow) do
    pins = list_pins(session)
    nodes_by_id = Map.new(workflow.nodes || [], &{&1.id, &1})

    pins
    |> Map.new(fn pin ->
      node = Map.get(nodes_by_id, pin.node_id)

      status = %{
        "id" => pin.id,
        "node_id" => pin.node_id,
        "label" => pin.label,
        "pinned_at" => pin.pinned_at,
        "data" => pin.data,
        "node_exists" => not is_nil(node),
        "stale" =>
          is_nil(node) or pin.node_config_hash != Imgd.Workflows.compute_node_config_hash(node),
        "source_hash_match" => pin.source_hash == session.base_source_hash
      }

      {pin.node_id, status}
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
