defmodule Imgd.Sandbox.ValidatorTest do
  use ExUnit.Case, async: true
  alias Imgd.Sandbox.{Validator, Config}

  describe "validate_code/2" do
    test "returns :ok for valid code within limits" do
      config = Config.build(max_code_size: 100)
      code = "return 1;"
      assert :ok = Validator.validate_code(code, config)
    end

    test "returns error when code exceeds max size" do
      config = Config.build(max_code_size: 5)
      code = "123456"
      assert {:error, {:code_too_large, 6, 5}} = Validator.validate_code(code, config)
    end

    test "returns error when code is not a binary" do
      config = Config.build(max_code_size: 100)

      assert {:error, {:validation_error, "code must be a string"}} =
               Validator.validate_code(123, config)
    end
  end

  describe "validate_args/1" do
    test "returns :ok for valid JSON-encodable args" do
      args = %{"a" => 1, "b" => [2, 3], "c" => %{"d" => "e"}}
      assert :ok = Validator.validate_args(args)
    end

    test "returns error for non-encodable args (PID)" do
      args = %{"pid" => self()}
      assert {:error, {:invalid_args, _}} = Validator.validate_args(args)
    end

    test "returns error for non-encodable args (Tuple)" do
      args = %{"tuple" => {1, 2}}
      assert {:error, {:invalid_args, _}} = Validator.validate_args(args)
    end

    test "returns error when args is not a map" do
      assert {:error, {:validation_error, "args must be a map"}} = Validator.validate_args([1, 2])
    end
  end
end
