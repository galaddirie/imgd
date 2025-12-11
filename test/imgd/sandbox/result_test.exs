defmodule Imgd.Sandbox.ResultTest do
  use ExUnit.Case, async: true
  alias Imgd.Sandbox.Result

  describe "parse/1" do
    test "parses successful result" do
      json = ~s({"ok": true, "value": 42})
      assert {:ok, 42} = Result.parse(json)
    end

    test "parses successful result with complex value" do
      json = ~s({"ok": true, "value": {"a": [1, 2], "b": "hello"}})
      assert {:ok, %{"a" => [1, 2], "b" => "hello"}} = Result.parse(json)
    end

    test "parses runtime error" do
      json = ~s({"ok": false, "error": "Something went wrong"})
      assert {:error, {:runtime_error, "Something went wrong"}} = Result.parse(json)
    end

    test "handles unexpected JSON structure" do
      json = ~s({"foo": "bar"})
      assert {:error, {:unexpected_result, %{"foo" => "bar"}}} = Result.parse(json)
    end

    test "handles invalid JSON" do
      json = "{invalid json}"
      assert {:error, {:invalid_json, "{invalid json}"}} = Result.parse(json)
    end

    test "handles non-binary input" do
      assert {:error, {:invalid_json, ":atom"}} = Result.parse(:atom)
    end
  end
end
