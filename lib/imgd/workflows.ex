defmodule Imgd.Workflows do
  @moduledoc """
  Workflow helpers that normalize data for hashing and comparisons.
  """

  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Workflows.WorkflowVersion

  @doc """
  Computes a stable hash for workflow draft attributes.
  """
  @spec compute_source_hash_from_attrs(list(), list(), list()) :: String.t()
  def compute_source_hash_from_attrs(nodes, connections, triggers) do
    WorkflowVersion.compute_source_hash(nodes || [], connections || [], triggers || [])
  end

  @doc """
  Computes a hash for a node's config to detect stale pins.
  """
  @spec compute_node_config_hash(Node.t() | map()) :: String.t()
  def compute_node_config_hash(%Node{} = node) do
    node
    |> Map.from_struct()
    |> compute_node_config_hash()
  end

  def compute_node_config_hash(%{} = node) do
    type_id = Map.get(node, :type_id) || Map.get(node, "type_id")
    config = Map.get(node, :config) || Map.get(node, "config") || %{}
    payload = %{type_id: type_id, config: config}

    payload
    |> Jason.encode!()
    |> hash_sha256()
  end

  defp hash_sha256(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
