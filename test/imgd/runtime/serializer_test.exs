defmodule Imgd.Runtime.SerializerTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Serializer

  describe "sanitize/2" do
    test "normalizes nested structures and keys" do
      value = %{
        status: :ok,
        meta: %{count: 1},
        tags: [:alpha, :beta],
        tuple: {:ok, 1}
      }

      assert %{
               "status" => "ok",
               "meta" => %{"count" => 1},
               "tags" => ["alpha", "beta"],
               "tuple" => ["ok", 1]
             } = Serializer.sanitize(value)
    end

    test "inspects pids, refs, and functions" do
      value = %{pid: self(), ref: make_ref(), fun: fn -> :ok end}
      sanitized = Serializer.sanitize(value)

      assert is_binary(sanitized["pid"])
      assert is_binary(sanitized["ref"])
      assert is_binary(sanitized["fun"])
    end
  end

  describe "wrap_for_db/1" do
    test "preserves booleans and nils for map fields" do
      value = %{ok: true, missing: nil, status: :ok}

      assert %{"ok" => true, "missing" => nil, "status" => "ok"} =
               Serializer.wrap_for_db(value)
    end

    test "wraps non-map values in a value map" do
      assert %{"value" => "hello"} = Serializer.wrap_for_db("hello")
    end

    test "returns nil when given nil" do
      assert Serializer.wrap_for_db(nil) == nil
    end
  end
end
