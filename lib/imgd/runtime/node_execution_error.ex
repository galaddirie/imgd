defmodule Imgd.Runtime.NodeExecutionError do
  @moduledoc """
  Exception raised when a node execution fails.
  """
  defexception [:node_id, :node_type_id, :reason]

  @impl true
  def message(%{node_id: node_id, node_type_id: type_id, reason: reason}) do
    "Node #{node_id} (#{type_id}) failed: #{inspect(reason)}"
  end
end
