defmodule Imgd.Collaboration.EditSession.Presence do
  @moduledoc """
  Tracks user presence in edit sessions using Phoenix.Presence.

  Manages:

  - Who is currently in the session
  - Cursor positions
  - Node selections
  - Node focus (config panel open)
  """
  use Phoenix.Presence,
    otp_app: :imgd,
    pubsub_server: Imgd.PubSub


  @type presence_meta :: %{
    user: map(),
    cursor: %{x: number(), y: number()} | nil,
    selected_nodes: [String.t()],
    focused_node: String.t() | nil,
    joined_at: DateTime.t()
  }

  @doc "Topic for a workflow's edit session presence."
  def topic(workflow_id), do: "edit_presence:#{workflow_id}"

  @doc "Track a user joining an edit session."
  def track_user(workflow_id, user, socket_or_pid) do
    track(socket_or_pid, topic(workflow_id), user.id, %{
      user: %{
        id: user.id,
        email: user.email,
        name: user.name || user.email
      },
      cursor: nil,
      selected_nodes: [],
      focused_node: nil,
      joined_at: DateTime.utc_now()
    })
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
end
