defmodule Imgd.SandboxTest do
  use ExUnit.Case, async: true

  alias Imgd.Sandbox
  alias Imgd.Sandbox.Error

  setup do
    unless Process.whereis(Imgd.Sandbox.Runner) do
      start_supervised!(Imgd.Sandbox.Supervisor)
    end

    :ok
  end

  describe "eval/2" do
    test "evaluates simple code with args" do
      assert {:ok, 6} =
               Sandbox.eval("return args.a + args.b;", args: %{a: 1, b: 5})
    end

    test "supports Promise results" do
      code = """
      return Promise.resolve(args.value * 3);
      """

      assert {:ok, 12} = Sandbox.eval(code, args: %{value: 4})
    end

    test "handles BigInt serialization (as string)" do
      # JS BigInts should be serialized as "bigint:123" string to avoid precision loss in JSON
      code = "return BigInt(9007199254740991) + 10n;"
      assert {:ok, "bigint:9007199254741001"} = Sandbox.eval(code)
    end

    test "handles Circular references" do
      code = """
      const a = { name: 'a' };
      a.self = a;
      return a;
      """
      # The safeValue implementation returns "[Circular]" for circular refs
      assert {:ok, %{"name" => "a", "self" => "[Circular]"}} = Sandbox.eval(code)
    end

    test "handles complex nested structures" do
      args = %{
        "users" => [
          %{"id" => 1, "meta" => %{"role" => "admin"}},
          %{"id" => 2, "meta" => %{"role" => "user"}}
        ]
      }

      code = """
      return args.users.map(u => ({ id: u.id, role: u.meta.role }));
      """

      assert {:ok, [%{"id" => 1, "role" => "admin"}, %{"id" => 2, "role" => "user"}]} =
               Sandbox.eval(code, args: args)
    end

    test "captures console logs on error" do
      code = """
      console.log("Starting calculation...");
      console.warn("Something looks fishy");
      throw new Error("Boom");
      """

      assert {:error, %Error{type: :runtime_error, message: message}} = Sandbox.eval(code)
      assert message =~ "Boom"
      # The exact format depends on how stdout captures it, but it should be present
      assert message =~ "Starting calculation..."
      assert message =~ "Something looks fishy"
    end
  end

  describe "resource limits" do
    test "terminates infinite loops (fuel exhaustion)" do
      code = "while (true) {}"

      assert {:error, %Error{type: :fuel_exhausted}} =
               Sandbox.eval(code, fuel: 100_000)
    end

    test "terminates on memory exhaustion" do
      # Allocate a large string instantly to trigger memory limit
      # 2MB limit
      code = """
      const s = "a".repeat(1024 * 1024 * 5); // 5MB
      return s.length;
      """

      # This typically results in :memory_exceeded or :runtime_error (out of memory)
      # or internal error if wasm traps
      assert {:error, error} = Sandbox.eval(code, memory_mb: 2)

      assert error.type in [:memory_exceeded, :internal_error, :runtime_error]
      if error.type == :memory_exceeded do
         assert error.message =~ "memory"
      end
    end

    test "enforces max output size" do
      code = "return 'a'.repeat(5000);"

      assert {:error, %Error{type: :runtime_error, message: msg}} =
               Sandbox.eval(code, max_output_size: 100)

      assert msg =~ "Output exceeds max size"
    end

    test "enforces max code size" do
      code = String.duplicate("a", 200)
      assert {:error, %Error{type: :validation_error, message: msg}} =
               Sandbox.eval(code, max_code_size: 100)

      assert msg =~ "Code size"
    end

    test "rejects non-positive config values" do
      assert {:error, %Error{type: :validation_error, message: msg}} =
               Sandbox.eval("return 1;", fuel: 0)

      assert msg =~ "fuel must be a positive integer"
    end

    @tag :capture_log
    test "handles timeout" do
      Process.flag(:trap_exit, true)
      # Use a long loop with high fuel to allow timeout to trigger first
      code = "while(true) {}"

      # Short timeout, massive fuel
      assert {:error, %Error{type: :timeout, message: msg}} =
               Sandbox.eval(code, timeout: 250, fuel: 100_000_000_000)

      assert msg =~ "exceeded 250ms timeout"
    end
  end

  describe "telemetry" do
    test "emits start and stop events" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test_telemetry_#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:sandbox, :eval, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Sandbox.eval("return 1 + 1;")

      assert_receive {:telemetry_event, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.status == :ok
      assert is_integer(metadata.code_size)
      assert is_integer(metadata.fuel_consumed)
    end
  end

  describe "concurrency" do
    test "handles multiple concurrent requests" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Sandbox.eval("return args.i * 2;", args: %{i: i})
          end)
        end

      results = Task.await_many(tasks)

      for {{:ok, val}, i} <- Enum.with_index(results, 1) do
        assert val == i * 2
      end
    end
  end

  describe "eval!/2" do
    test "returns result on success" do
      assert 3 = Sandbox.eval!("return 1 + 2;")
    end

    test "raises error on failure" do
      assert_raise Error, ~r/Boom/, fn ->
        Sandbox.eval!("throw new Error('Boom')")
      end
    end
  end
end
