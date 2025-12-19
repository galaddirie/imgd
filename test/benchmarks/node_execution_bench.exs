# Run with:
#   mix run test/benchmarks/node_execution_bench.exs
#   mix run test/benchmarks/node_execution_bench.exs -- --mode cprof
#   mix run test/benchmarks/node_execution_bench.exs -- --mode eprof
#   mix run test/benchmarks/node_execution_bench.exs -- --mode fprof
#   mix run test/benchmarks/node_execution_bench.exs -- --mode all
#   mix run test/benchmarks/node_execution_bench.exs -- --iterations 5000 --warmup 200
#   mix run test/benchmarks/node_execution_bench.exs -- --profile-iterations 2000 --fprof-procs all

alias Imgd.Graph
alias Imgd.Executions.Execution
alias Imgd.Runtime.Core.{Expression, NodeRunner}
alias Imgd.Runtime.Expression.Context
alias Imgd.Workflows.Embeds.Node

defmodule NodeBench do
  @default_iterations 1000
  @default_warmup 20
  @default_profile_iterations 500
  @default_log_level :error

  def run do
    opts = parse_args(System.argv())
    Logger.configure(level: opts[:log_level])

    {execution, context, context_fun} = build_context()
    benchmarks = build_benchmarks(execution, context, context_fun)

    case opts[:mode] do
      :bench ->
        run_benchmarks(benchmarks, opts)

      :cprof ->
        run_cprof(benchmarks, opts)

      :eprof ->
        run_eprof(benchmarks, opts)

      :fprof ->
        run_fprof(benchmarks, opts)

      :all ->
        run_benchmarks(benchmarks, opts)
        run_cprof(benchmarks, opts)
        run_eprof(benchmarks, opts)
        run_fprof(benchmarks, opts)
    end
  end

  defp parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        switches: [
          mode: :string,
          iterations: :integer,
          warmup: :integer,
          profile_iterations: :integer,
          fprof_procs: :string,
          fprof_dest: :string,
          log_level: :string,
          gc: :boolean
        ]
      )

    %{
      mode: parse_mode(opts[:mode]),
      iterations: opts[:iterations] || @default_iterations,
      warmup: opts[:warmup] || @default_warmup,
      profile_iterations: opts[:profile_iterations] || @default_profile_iterations,
      fprof_procs: parse_fprof_procs(opts[:fprof_procs] || "self"),
      fprof_dest: opts[:fprof_dest] || "tmp/profiles",
      log_level: parse_log_level(opts[:log_level]),
      gc: opts[:gc] || false
    }
  end

  defp parse_mode(nil), do: :bench
  defp parse_mode("bench"), do: :bench
  defp parse_mode("cprof"), do: :cprof
  defp parse_mode("eprof"), do: :eprof
  defp parse_mode("fprof"), do: :fprof
  defp parse_mode("all"), do: :all

  defp parse_mode(other) do
    IO.puts("Unknown mode: #{other}. Falling back to bench.")
    :bench
  end

  defp parse_log_level(nil), do: @default_log_level

  defp parse_log_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      "none" -> :none
      _ -> @default_log_level
    end
  end

  defp parse_fprof_procs("all"), do: :all
  defp parse_fprof_procs(_), do: [self()]

  defp build_context do
    execution = %Execution{
      id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      workflow_version_id: Ecto.UUID.generate(),
      status: :running,
      trigger: %Execution.Trigger{type: :manual, data: %{"value" => 42}},
      context: %{}
    }

    context = %{
      "json" => %{"x" => 10, "y" => 20},
      "nodes" => %{
        "node_1" => %{"json" => %{"result" => 100}}
      }
    }

    context_fun = fn -> context end

    {execution, context, context_fun}
  end

  defp build_benchmarks(execution, context, context_fun) do
    node_benchmarks = [
      {"Math node (add)",
       %Node{
         id: "math_1",
         type_id: "math",
         name: "Add",
         config: %{"operation" => "add", "operand" => 5}
       }, %{"value" => 10}},
      {"Debug node",
       %Node{
         id: "debug_1",
         type_id: "debug",
         name: "Log",
         config: %{"label" => "test", "level" => "debug"}
       }, %{"data" => "hello"}},
      {"Format node (template)",
       %Node{
         id: "format_1",
         type_id: "format",
         name: "Format",
         config: %{"template" => "Value: {{json.x}} + {{json.y}}"}
       }, %{"x" => 1, "y" => 2}}
    ]

    node_workloads =
      Enum.map(node_benchmarks, fn {name, node, input} ->
        fun = fn -> NodeRunner.run(node, input, context_fun, execution) end
        {name, fun, [NodeRunner, Expression]}
      end)

    expression_benchmarks = [
      {"Simple var", "{{ json.x }}"},
      {"Nested var", "{{ nodes.node_1.json.result }}"},
      {"With filter", "{{ json.x | plus: 10 }}"},
      {"Multiple vars", "x={{ json.x }}, y={{ json.y }}"}
    ]

    expression_workloads =
      Enum.map(expression_benchmarks, fn {name, template} ->
        label = "#{name}: \"#{template}\""
        fun = fn -> Expression.evaluate(template, context) end
        {label, fun, [Expression]}
      end)

    workflow_workloads = build_workflow_benchmarks()

    %{
      nodes: node_workloads,
      expressions: expression_workloads,
      workflows: workflow_workloads
    }
  end

  defp build_workflow_benchmarks do
    execution = %Execution{
      id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      workflow_version_id: Ecto.UUID.generate(),
      status: :running,
      trigger: %Execution.Trigger{type: :manual, data: %{"value" => 5}},
      context: %{}
    }

    {graph, order, node_map} = build_linear_math_workflow()
    input = %{"value" => 5}

    fun = fn ->
      run_workflow(graph, order, node_map, execution, input)
    end

    [
      {"Workflow: Linear Math (4 nodes)", fun, [NodeRunner, Graph, Context]}
    ]
  end

  defp build_linear_math_workflow do
    node_input =
      %Node{
        id: "debug_in",
        type_id: "debug",
        name: "Start",
        config: %{"label" => "Input", "level" => "info"}
      }

    node_add =
      %Node{
        id: "math_add",
        type_id: "math",
        name: "Add 10",
        config: %{"operation" => "add", "operand" => 10, "field" => "value"}
      }

    node_mult =
      %Node{
        id: "math_mult",
        type_id: "math",
        name: "Multiply by 2",
        config: %{"operation" => "multiply", "operand" => 2}
      }

    node_debug =
      %Node{
        id: "debug_out",
        type_id: "debug",
        name: "Result",
        config: %{"label" => "Final Value", "level" => "info"}
      }

    nodes = [node_input, node_add, node_mult, node_debug]

    connections = [
      %{source_node_id: node_input.id, target_node_id: node_add.id},
      %{source_node_id: node_add.id, target_node_id: node_mult.id},
      %{source_node_id: node_mult.id, target_node_id: node_debug.id}
    ]

    graph = Graph.from_workflow!(nodes, connections)
    order = Graph.topological_sort!(graph)
    node_map = Map.new(nodes, &{&1.id, &1})

    {graph, order, node_map}
  end

  defp run_workflow(graph, order, node_map, execution, trigger_input) do
    {_states, results} =
      Enum.reduce(order, {%{}, %{}}, fn node_id, {states, results} ->
        input = workflow_input(graph, node_id, results, trigger_input)

        context_fun = fn ->
          Context.build(execution, results, input)
        end

        case NodeRunner.run(Map.fetch!(node_map, node_id), input, context_fun, execution) do
          {:ok, output} ->
            {Map.put(states, node_id, :completed), Map.put(results, node_id, output)}

          {:skip, _reason} ->
            {Map.put(states, node_id, :skipped), results}

          {:error, reason} ->
            raise "workflow node #{node_id} failed: #{inspect(reason)}"
        end
      end)

    results
  end

  defp workflow_input(graph, node_id, results, trigger_input) do
    case Graph.parents(graph, node_id) do
      [] ->
        trigger_input

      [single] ->
        Map.get(results, single)

      multiple ->
        Map.new(multiple, fn pid -> {pid, Map.get(results, pid)} end)
    end
  end

  defp run_benchmarks(%{nodes: nodes, expressions: expressions, workflows: workflows}, opts) do
    IO.puts("\n=== Node Execution Benchmark ===\n")

    for {name, fun, _modules} <- nodes do
      bench(name, fun, opts)
    end

    IO.puts("=== Expression Evaluation ===\n")

    for {name, fun, _modules} <- expressions do
      bench(name, fun, opts)
    end

    IO.puts("=== Workflow Execution Benchmark ===\n")

    for {name, fun, _modules} <- workflows do
      bench(name, fun, opts)
    end
  end

  defp run_cprof(%{nodes: nodes, expressions: expressions}, opts) do
    IO.puts("\n=== cprof (call counts) ===\n")

    for {name, fun, modules} <- nodes ++ expressions do
      profile_cprof(name, fun, modules, opts)
    end
  end

  defp run_eprof(%{nodes: nodes, expressions: expressions}, opts) do
    IO.puts("\n=== eprof (time + counts) ===\n")

    for {name, fun, _modules} <- nodes ++ expressions do
      profile_eprof(name, fun, opts)
    end
  end

  defp run_fprof(%{nodes: nodes, expressions: expressions}, opts) do
    IO.puts("\n=== fprof (trace + time) ===\n")
    File.mkdir_p!(opts[:fprof_dest])

    for {name, fun, _modules} <- nodes ++ expressions do
      profile_fprof(name, fun, opts)
    end
  end

  defp bench(name, fun, opts) do
    maybe_gc(opts)
    warmup(fun, opts)

    times =
      for _ <- 1..opts[:iterations] do
        {time, _} = :timer.tc(fun)
        time
      end

    stats = summarize(times)
    ops = if stats.avg > 0, do: 1_000_000 / stats.avg, else: 0.0

    IO.puts(name)
    IO.puts("  avg: #{Float.round(stats.avg, 2)}us | ops/s: #{Float.round(ops, 1)}")
    IO.puts("  min: #{stats.min}us | p50: #{stats.p50}us | p90: #{stats.p90}us")
    IO.puts("  p95: #{stats.p95}us | p99: #{stats.p99}us | max: #{stats.max}us")
    IO.puts("  stddev: #{Float.round(stats.stddev, 2)}us")
    IO.puts("")
  end

  defp warmup(fun, opts) do
    for _ <- 1..opts[:warmup] do
      fun.()
    end

    :ok
  end

  defp summarize(times) do
    sorted = Enum.sort(times)
    count = length(sorted)
    avg = Enum.sum(sorted) / count
    stddev = stddev(sorted, avg)

    %{
      min: hd(sorted),
      max: List.last(sorted),
      avg: avg,
      p50: percentile(sorted, 0.50),
      p90: percentile(sorted, 0.90),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      stddev: stddev
    }
  end

  defp percentile(sorted, pct) do
    count = length(sorted)
    idx = Float.floor((count - 1) * pct) |> trunc()
    Enum.at(sorted, idx)
  end

  defp stddev(values, avg) do
    count = length(values)

    variance =
      Enum.reduce(values, 0.0, fn v, acc ->
        diff = v - avg
        acc + diff * diff
      end) / count

    :math.sqrt(variance)
  end

  defp maybe_gc(opts) do
    if opts[:gc] do
      :erlang.garbage_collect()
    end
  end

  defp profile_cprof(name, fun, modules, opts) do
    maybe_gc(opts)
    warmup(fun, opts)

    :cprof.start()

    run_profile_iterations(fun, opts)

    IO.puts(name)

    Enum.each(modules, fn mod ->
      :cprof.analyse(mod) |> print_cprof_result(mod)
    end)

    :cprof.stop()
    IO.puts("")
  end

  defp print_cprof_result({mod, total, results}, _expected_mod) do
    IO.puts("  #{inspect(mod)} total calls: #{total}")

    results
    |> Enum.sort_by(fn {_mfa, count} -> -count end)
    |> Enum.take(15)
    |> Enum.each(fn {mfa, count} ->
      IO.puts("    #{format_mfa(mfa)}: #{count}")
    end)
  end

  defp profile_eprof(name, fun, opts) do
    maybe_gc(opts)
    warmup(fun, opts)

    :eprof.start()
    :eprof.start_profiling([self()])

    run_profile_iterations(fun, opts)

    :eprof.stop_profiling()

    IO.puts(name)
    :eprof.analyze()
    :eprof.stop()
    IO.puts("")
  end

  defp profile_fprof(name, fun, opts) do
    maybe_gc(opts)
    warmup(fun, opts)

    trace_path = Path.join(opts[:fprof_dest], fprof_trace_name(name))
    analysis_path = Path.join(opts[:fprof_dest], fprof_analysis_name(name))

    :fprof.start()
    :fprof.trace([:start, procs: opts[:fprof_procs]])

    run_profile_iterations(fun, opts)

    :fprof.trace(:stop)
    :fprof.profile(dest: String.to_charlist(trace_path))

    IO.puts(name)
    :fprof.analyse(totals: false, dest: String.to_charlist(analysis_path))
    :fprof.stop()

    IO.puts("  fprof trace: #{trace_path}")
    IO.puts("  fprof analysis: #{analysis_path}")
    IO.puts("")
  end

  defp run_profile_iterations(fun, opts) do
    for _ <- 1..opts[:profile_iterations] do
      fun.()
    end

    :ok
  end

  defp fprof_trace_name(name) do
    "fprof_#{slugify(name)}.trace"
  end

  defp fprof_analysis_name(name) do
    "fprof_#{slugify(name)}.analysis"
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp format_mfa({m, f, a}) do
    "#{inspect(m)}.#{f}/#{a}"
  end
end

NodeBench.run()
