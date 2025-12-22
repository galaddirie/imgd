defmodule Imgd.Collaboration.EditSession.Presence do
  @moduledoc """
  Tracks user presence in edit sessions using Phoenix.Presence.

  Manages:

  - Who is currently in the session
  - Cursor positions
  - Node selections
  - Node focus (config panel open)

  Note: Subscription to presence updates should go through
  `Imgd.Collaboration.EditSession.PubSub.subscribe_presence/2` which
  enforces scope-based authorization.
  """
  use Phoenix.Presence,
    otp_app: :imgd,
    pubsub_server: Imgd.PubSub

  alias Imgd.Collaboration.EditSession.PubSub, as: EditPubSub

  @type presence_meta :: %{
          user: map(),
          cursor: %{x: number(), y: number()} | nil,
          selected_nodes: [String.t()],
          focused_node: String.t() | nil,
          joined_at: DateTime.t()
        }

  @doc "Topic for a workflow's edit session presence."
  def topic(workflow_id), do: EditPubSub.presence_topic(workflow_id)

  @doc "Track a user joining an edit session."
  def track_user(workflow_id, user, %Phoenix.LiveView.Socket{}) do
    track(self(), topic(workflow_id), user.id, build_meta(user))
  end

  def track_user(workflow_id, user, %Phoenix.Socket{} = socket) do
    track(socket, topic(workflow_id), user.id, build_meta(user))
  end

  def track_user(workflow_id, user, pid) when is_pid(pid) do
    track(pid, topic(workflow_id), user.id, build_meta(user))
  end

  @doc "Update user's cursor position."
  def update_cursor(workflow_id, user_id, position) do
    update(self(), topic(workflow_id), user_id, fn meta ->
      Map.put(meta, :cursor, position)
    end)
  end

  @doc "Update user's node selection."
  def update_selection(workflow_id, user_id, node_ids) do
    update(self(), topic(workflow_id), user_id, fn meta ->
      Map.put(meta, :selected_nodes, node_ids)
    end)
  end

  @doc "Update user's focused node (config panel open)."
  def update_focus(workflow_id, user_id, node_id) do
    update(self(), topic(workflow_id), user_id, fn meta ->
      Map.put(meta, :focused_node, node_id)
    end)
  end

  @doc "Clear user's focus."
  def clear_focus(workflow_id, user_id) do
    update_focus(workflow_id, user_id, nil)
  end

  @doc "Get all users in a session."
  def list_users(workflow_id) do
    list(topic(workflow_id))
  end

  @doc "Count users in a session."
  def count(workflow_id) do
    workflow_id
    |> topic()
    |> list()
    |> map_size()
  end

  @doc "Get a specific user's presence."
  def get_user(workflow_id, user_id) do
    workflow_id
    |> list_users()
    |> Map.get(user_id)
  end

  defp build_meta(user) do
    name = Map.get(user, :name) || user.email

    %{
      user: %{
        id: user.id,
        email: user.email,
        name: name
      },
      cursor: nil,
      selected_nodes: [],
      focused_node: nil,
      joined_at: DateTime.utc_now()
    }
  end
end
