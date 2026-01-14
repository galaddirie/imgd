defmodule RuntimeBenchmark do
  @moduledoc """
  Benchmark for workflow runtime components.
  Run with: `mix run priv/benchmarks/runtime_benchmark.exs`
  """

  alias Imgd.Runtime.Expression
  alias Imgd.Runtime.Steps.StepRunner
  alias Imgd.Runtime.Expression.Context
  alias Imgd.Runtime.Serializer
  alias Imgd.Graph
  alias Imgd.Runtime.RunicAdapter

  def run do
    IO.puts("=== Workflow Runtime Benchmarks ===")

    benchmark_expression_evaluation()
    benchmark_data_processing()
    benchmark_graph_ops()
    benchmark_step_runner()
  end

  defp benchmark_expression_evaluation do
    IO.puts("\n--- Expression Evaluation ---")

    vars = %{
      "json" => %{"name" => "World", "amount" => 100},
      "steps" => %{"Previous" => %{"json" => %{"status" => "success"}}},
      "variables" => %{"key" => "value"}
    }

    simple_template = "Hello {{ json.name }}!"

    measure("Expression.evaluate (simple template)", fn ->
      {:ok, _} = Expression.evaluate(simple_template, vars)
    end)

    measure("Task.async/yield overhead (baseline)", fn ->
      task = Task.async(fn -> :ok end)
      Task.yield(task, 5000) || Task.shutdown(task)
    end)
  end

  defp benchmark_data_processing do
    IO.puts("\n--- Data Normalization & Serialization ---")

    large_map = Map.new(1..100, fn i -> {"key_#{i}", "value_#{i}"} end)

    measure("Serializer.sanitize (100 keys)", fn ->
      Serializer.sanitize(large_map)
    end)

    ctx = %Imgd.Runtime.ExecutionContext{
      input: large_map,
      step_outputs: %{"Step1" => large_map, "Step2" => large_map}
    }

    measure("Context.build_from_context (2 upstream steps, 100 keys each)", fn ->
      Context.build_from_context(ctx)
    end)
  end

  defp benchmark_graph_ops do
    IO.puts("\n--- Graph Operations ---")

    # Build a graph of 50 steps
    steps = Enum.map(1..50, fn i -> %{id: "step_#{i}", type_id: "debug", name: "Step #{i}", config: %{}} end)
    connections = Enum.map(1..49, fn i -> %{source_step_id: "step_#{i}", target_step_id: "step_#{i+1}"} end)

    graph = Graph.new(Enum.map(steps, & &1.id), Enum.map(connections, fn c -> {c.source_step_id, c.target_step_id} end))

    measure("Graph.upstream (linear 50 steps)", fn ->
      Graph.upstream(graph, "step_50")
    end)

    source = %{
      id: "wf_1",
      steps: steps,
      connections: connections
    }

    measure("RunicAdapter.to_runic_workflow (50 steps)", fn ->
      RunicAdapter.to_runic_workflow(source)
    end)
  end

  defp benchmark_step_runner do
    IO.puts("\n--- Step Runner ---")

    step = %{
      id: "math_1",
      type_id: "math",
      config: %{
        "operation" => "add",
        "value" => "{{ json.amount }}",
        "operand" => 10
      }
    }

    input = %{"amount" => 100}

    opts = [
      execution_id: "test_exec",
      workflow_id: "test_wf",
      variables: %{"global" => "foo"},
      trigger_type: :manual
    ]

    measure("StepRunner.execute_with_context (math step)", fn ->
      try do
        StepRunner.execute_with_context(step, input, opts)
      catch
        _kind, _reason -> nil
      end
    end)
  end

  defp measure(label, func) do
    Enum.each(1..10, fn _ -> func.() end)

    iterations = 100
    {time, _} = :timer.tc(fn ->
      Enum.each(1..iterations, fn _ -> func.() end)
    end)

    avg_ms = time / iterations / 1000
    IO.puts("#{label}: #{Float.round(avg_ms, 3)}ms average over #{iterations} iterations")
  end
end

RuntimeBenchmark.run()
