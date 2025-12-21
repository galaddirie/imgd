defmodule Imgd.Runtime.Expression.CacheTest do
  use ExUnit.Case, async: false

  alias Imgd.Runtime.Expression.Cache

  setup do
    ensure_cache_started()
    Cache.clear()
    :ok
  end

  test "get_or_compile/1 caches templates by content" do
    template = "Hello {{ name }}"

    assert {:ok, _compiled} = Cache.get_or_compile(template)
    assert %{entries: 1} = Cache.stats()

    assert {:ok, _compiled} = Cache.get_or_compile(template)
    assert %{entries: 1} = Cache.stats()
  end

  test "invalidate/1 removes a specific template from cache" do
    assert {:ok, _compiled} = Cache.get_or_compile("Hello {{ name }}")
    assert {:ok, _compiled} = Cache.get_or_compile("Bye {{ name }}")
    assert %{entries: 2} = Cache.stats()

    Cache.invalidate("Hello {{ name }}")
    assert %{entries: 1} = Cache.stats()
  end

  test "clear/0 removes all cached templates" do
    assert {:ok, _compiled} = Cache.get_or_compile("Hello {{ name }}")
    assert %{entries: 1} = Cache.stats()

    Cache.clear()
    assert %{entries: 0} = Cache.stats()
  end

  defp ensure_cache_started do
    if Process.whereis(Cache) == nil do
      start_supervised!(Cache)
    end
  end
end
