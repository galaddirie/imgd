defmodule Imgd.Engine.DataFlowTest do
  use ExUnit.Case, async: true

  alias Imgd.Engine.DataFlow
  alias Imgd.Engine.DataFlow.ValidationError

  describe "prepare_input/2" do
    test "wraps and validates input against a schema" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      {:ok, envelope} =
        DataFlow.prepare_input(%{"name" => "Jane"}, schema: schema, metadata: %{extra: "test"})

      assert envelope.value == %{"name" => "Jane"}
      assert envelope.metadata.source == :input
      assert is_binary(envelope.metadata.trace_id)
      assert envelope.metadata[:extra] == "test"
    end

    test "returns a validation error for invalid data" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      assert {:error, %ValidationError{code: :type_mismatch}} =
               DataFlow.prepare_input(%{"name" => 123}, schema: schema)
    end
  end

  describe "wrap/unwrap helpers" do
    test "wraps values with metadata and unwraps them" do
      envelope =
        DataFlow.wrap("value",
          source: :step,
          step_hash: 123,
          fact_hash: 456,
          trace_id: "trace"
        )

      assert DataFlow.wrapped?(envelope)
      assert DataFlow.unwrap(envelope) == "value"
      assert envelope.metadata.step_hash == 123
      assert envelope.metadata.fact_hash == 456

      refute DataFlow.wrapped?(%{foo: :bar})
    end
  end

  describe "serialize_for_storage/1" do
    test "normalizes maps and atoms for storage" do
      serialized = DataFlow.serialize_for_storage(%{status: :ok, nested: %{flag: true}})

      assert serialized["type"] == "map"
      assert serialized["value"] == %{"status" => :ok, "nested" => %{"flag" => true}}
    end

    test "flags non-serializable values" do
      serialized = DataFlow.serialize_for_storage(fn -> :ok end)

      assert serialized["type"] == "non_serializable"
      assert serialized["inspect"] =~ "#Function<"
    end
  end

  describe "snapshot/2" do
    test "truncates large JSON-encodable values" do
      value = %{"big" => String.duplicate("a", 200)}

      snapshot = DataFlow.snapshot(value, max_size: 50, preview_size: 10)

      assert snapshot["_truncated"]
      assert snapshot["_original_size"] > 50
      assert String.length(snapshot["_preview"]) == 10
    end

    test "handles non-JSON encodable values" do
      snapshot = DataFlow.snapshot(self())

      assert snapshot["_non_json"]
      assert snapshot["_type"] == "pid"
      assert snapshot["_inspect"] =~ "#PID"
    end
  end
end
