defmodule Imgd.Steps.RegistryDefaultConfigTest do
  use ExUnit.Case, async: true
  alias Imgd.Steps.Registry

  test "get_default_config/1 returns UUID for webhook_trigger" do
    config = Registry.get_default_config("webhook_trigger")
    assert is_binary(config["path"])
    assert {:ok, _} = Ecto.UUID.cast(config["path"])
    assert config["http_method"] == "POST"
    assert config["response_mode"] == "immediate"
  end

  test "get_default_config/1 returns empty map for steps without default_config" do
    # 'debug' executor doesn't have an explicit @default_config in its source (I checked during research)
    config = Registry.get_default_config("debug")
    assert config == %{}
  end

  test "get_default_config/1 returns empty map for non-existent step types" do
    config = Registry.get_default_config("non_existent_step")
    assert config == %{}
  end
end
