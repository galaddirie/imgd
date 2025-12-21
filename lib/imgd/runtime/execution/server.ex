defmodule Imgd.Runtime.Execution.Server do
  @moduledoc """
  OTP process representing a single workflow execution.
  Uses Runic as the core dataflow engine.
  """
  use GenServer, restart: :temporary

  require Logger
  alias Runic.Workflow
  alias Imgd.Runtime.RunicAdapter
  alias Imgd.Runtime.Events
  alias Imgd.Runtime.Hooks.Observability
  alias Imgd.Executions.Execution
  alias Imgd.Repo

  defmodule State do
    defstruct [:execution_id, :runic_workflow, :status, :metadata]
  end

  # ============================================================================
  # API
  # ============================================================================

  def start_link(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)
    GenServer.start_link(__MODULE__, execution_id, name: via_tuple(execution_id))
  end

  defp via_tuple(execution_id) do
    {:via, Registry, {Imgd.Runtime.Execution.Registry, execution_id}}
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(execution_id) do
    Logger.metadata(execution_id: execution_id)
    Logger.info("Initializing execution server")

    case load_with_source(execution_id) do
      {:ok, execution} ->
        case build_runic_workflow(execution) do
          {:ok, runic_wrk} ->
            state = %State{
              execution_id: execution_id,
              runic_workflow: runic_wrk,
              status: execution.status,
              metadata: execution.metadata
            }

            # Trigger execution if process was started for a pending/running execution
            case execution.status do
              s when s in [:pending, :running] ->
                send(self(), :run)

              _ ->
                :ok
            end

            {:ok, state}

          {:error, :missing_source} ->
            Logger.error("Execution missing workflow source", execution_id: execution_id)
            {:stop, :missing_source}
        end

      {:error, :not_found} ->
        {:stop, :not_found}
    end
  end

  @impl true
  def handle_info(:run, state) do
    # Transition to running in DB if pending
    if state.status == :pending do
      update_status(state.execution_id, :running)
    end

    # Emit execution started event
    Events.emit(:execution_started, state.execution_id, %{status: :running})

    # Get initial trigger data
    trigger_data = fetch_trigger_data(state.execution_id)

    # Execute Runic cycles
    try do
      # For now, we run until completion or wait state.
      # Runic's react_until_satisfied is the primary driver.
      new_runic_wrk = Workflow.react_until_satisfied(state.runic_workflow, trigger_data)

      # Sync the Runic graph results back to the Imgd context
      new_state = %{state | runic_workflow: new_runic_wrk, status: :completed}
      finalize_execution(new_state)

      # Emit completion event
      Events.emit(:execution_completed, state.execution_id, %{status: :completed})

      {:stop, :normal, new_state}
    catch
      :throw, {:node_error, node_id, reason} ->
        handle_failure(state, node_id, reason)
        {:stop, :normal, state}

      kind, reason ->
        Logger.error("Execution failed unexpectedly: #{inspect(reason)}",
          kind: kind,
          stacktrace: __STACKTRACE__
        )

        handle_failure(state, "system", reason)
        {:stop, :normal, state}
    end
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp load_with_source(id) do
    execution =
      Execution
      |> Repo.get(id)
      |> Repo.preload(workflow: :draft)

    if execution, do: {:ok, execution}, else: {:error, :not_found}
  end

  defp build_runic_workflow(execution) do
    # Hydrate Runic Workflow (from snapshot or build from draft)
    runic_wrk =
      cond do
        execution.runic_snapshot ->
          hydrate_from_snapshot(execution.runic_snapshot)

        execution.runic_log && length(execution.runic_log) > 0 ->
          # Option for replaying construction log here if needed
          build_from_source(execution)

        true ->
          # Fresh start
          build_from_source(execution)
      end

    if runic_wrk do
      # Attach observability hooks for logging, telemetry, events
      hooked_wrk =
        Observability.attach_all_hooks(runic_wrk,
          execution_id: execution.id,
          workflow_id: execution.workflow_id
        )

      {:ok, hooked_wrk}
    else
      {:error, :missing_source}
    end
  end

  defp build_from_source(execution) do
    case get_source(execution) do
      nil ->
        nil

      source ->
        # Pass execution context to the adapter
        opts = [
          execution_id: execution.id,
          variables: Map.get(execution.metadata, "variables", %{}),
          metadata: %{
            trace_id: Map.get(execution.metadata, "trace_id"),
            workflow_id: execution.workflow_id
          }
        ]

        RunicAdapter.to_runic_workflow(source, opts)
    end
  end

  defp hydrate_from_snapshot(binary) do
    :erlang.binary_to_term(binary)
  rescue
    e ->
      Logger.error("Failed to hydrate execution snapshot: #{inspect(e)}")
      nil
  end

  defp get_source(%Execution{workflow: %{draft: draft}}), do: draft
  defp get_source(_), do: nil

  defp fetch_trigger_data(id) do
    # In a real app, we'd load this from the 'trigger' field
    execution = Repo.get!(Execution, id)
    execution.trigger.data || %{}
  end

  defp update_status(id, status) do
    Execution
    |> Repo.get!(id)
    |> Execution.changeset(%{status: status, started_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp finalize_execution(state) do
    wrk = state.runic_workflow
    context = build_context_from_runic(wrk)

    # Get serializable Runic log
    runic_log =
      wrk
      |> Workflow.log()
      |> Enum.map(&Imgd.Runtime.Serializer.sanitize/1)

    # Binary snapshot for fast resumption
    snapshot = :erlang.term_to_binary(wrk)

    Execution
    |> Repo.get!(state.execution_id)
    |> Execution.changeset(%{
      status: :completed,
      context: context,
      runic_log: runic_log,
      runic_snapshot: snapshot,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    Logger.info("Execution completed successfully")
  end

  defp handle_failure(state, node_id, reason) do
    error_map = Execution.format_error({:node_failed, node_id, reason})

    Execution
    |> Repo.get!(state.execution_id)
    |> Execution.changeset(%{
      status: :failed,
      error: error_map,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    Logger.error("Execution failed at node #{node_id}: #{inspect(reason)}")
  end

  defp build_context_from_runic(wrk) do
    graph = wrk.graph

    # 1. Find all facts in the graph
    facts =
      graph
      |> Graph.vertices()
      |> Enum.filter(&match?(%Runic.Workflow.Fact{}, &1))

    # 2. Map each fact to its producing step's name
    # Runic steps are named with Imgd Node IDs in the adapter
    facts
    |> Enum.reduce(%{}, fn fact, acc ->
      producing_step =
        graph
        |> Graph.in_neighbors(fact)
        |> Enum.find(&match?(%Runic.Workflow.Step{}, &1))

      case producing_step do
        %{name: name} when is_binary(name) ->
          # If multiple facts from same node (unlikely in current Imgd BUT
          # possible in Runic collections), we might want to store as list
          # or latest. For compatibility, we'll store as single value.
          Map.put(acc, name, fact.value)

        _ ->
          acc
      end
    end)
  end
end
