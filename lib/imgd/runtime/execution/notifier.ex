defmodule Imgd.Runtime.Execution.Notifier do
  @moduledoc """
  Handles notification of runtime events to the outside world
  via PubSub and Telemetry.
  """

  alias Imgd.Executions.PubSub
  alias Imgd.Executions.{Execution, NodeExecution}

  @doc """
  Emit execution lifecycle events.
  events: :started, :completed, :failed
  """
  def broadcast_execution_event(event, %Execution{} = execution) do
    # 1. Telemetry
    emit_telemetry([:execution, event], %{id: execution.id}, %{execution: execution})

    # 2. PubSub
    case event do
      :started -> PubSub.broadcast_execution_started(execution)
      :completed -> PubSub.broadcast_execution_completed(execution)
      :failed -> PubSub.broadcast_execution_failed(execution)
    end
  end

  @doc """
  Emit node lifecycle events.
  events: :started, :completed, :failed
  """
  def broadcast_node_event(event, %Execution{} = execution, %NodeExecution{} = node_exec) do
    # 1. Telemetry
    emit_telemetry(
      [:node, event],
      %{execution_id: execution.id, node_id: node_exec.node_id},
      %{node_execution: node_exec}
    )

    # 2. PubSub
    case event do
      :started -> PubSub.broadcast_node_started(execution, node_exec)
      :completed -> PubSub.broadcast_node_completed(execution, node_exec)
      :failed -> PubSub.broadcast_node_failed(execution, node_exec)
      _ -> :ok
    end
  end

  defp emit_telemetry(suffix, measurements, metadata) do
    :telemetry.execute(
      [:imgd, :workflow] ++ suffix,
      measurements,
      metadata
    )
  end
end
