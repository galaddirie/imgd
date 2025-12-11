defmodule Imgd.Sandbox.ErrorTest do
  use ExUnit.Case, async: true
  alias Imgd.Sandbox.Error

  describe "wrap/1" do
    test "wraps timeout error" do
      error = Error.wrap({:timeout, 5000})
      assert error.type == :timeout
      assert error.message == "Execution exceeded 5000ms timeout"
      assert error.details == %{timeout_ms: 5000}
    end

    test "wraps fuel exhausted error" do
      error = Error.wrap(:fuel_exhausted)
      assert error.type == :fuel_exhausted
      assert error.message =~ "exceeded maximum allowed instructions"
    end

    test "wraps memory exceeded error" do
      error = Error.wrap(:memory_exceeded)
      assert error.type == :memory_exceeded
      assert error.message =~ "exceeded maximum allowed memory"
    end

    test "wraps runtime error" do
      error = Error.wrap({:runtime_error, "Boom"})
      assert error.type == :runtime_error
      assert error.message == "Boom"
    end

    test "wraps validation error" do
      error = Error.wrap({:validation_error, "Invalid input"})
      assert error.type == :validation_error
      assert error.message == "Invalid input"
    end

    test "wraps code size error" do
      error = Error.wrap({:code_too_large, 105, 100})
      assert error.type == :validation_error
      assert error.message == "Code size 105 exceeds limit of 100 bytes"
      assert error.details == %{actual: 105, max: 100}
    end

    test "wraps invalid args error" do
      error = Error.wrap({:invalid_args, "reason"})
      assert error.type == :validation_error
      assert error.message =~ "Args must be JSON encodable"
    end

    test "wraps wasm error" do
      error = Error.wrap({:wasm_error, "wasm trap"})
      assert error.type == :internal_error
      assert error.message =~ "WebAssembly error"
      assert error.details == %{reason: "wasm trap"}
    end

    test "wraps invalid json error" do
      error = Error.wrap({:invalid_json, "bad json"})
      assert error.type == :internal_error
      assert error.message == "Invalid JSON output from sandbox"
      assert error.details == %{output: "bad json"}
    end

    test "wraps unexpected error" do
      error = Error.wrap(:unknown_error)
      assert error.type == :internal_error
      assert error.message =~ "Unexpected error"
    end
  end

  describe "Exception.message/1" do
    test "formats message with type" do
      error = %Error{type: :timeout, message: "Timeout occurred"}
      assert Exception.message(error) == "[Sandbox.Timeout] Timeout occurred"
    end
  end
end
