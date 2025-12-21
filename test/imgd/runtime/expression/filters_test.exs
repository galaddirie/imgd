defmodule Imgd.Runtime.Expression.FiltersTest do
  use ExUnit.Case, async: true

  alias Imgd.Runtime.Expression.Filters

  describe "json filters" do
    test "json encodes and parse_json decodes" do
      encoded = Filters.json(%{"a" => 1})
      assert %{"a" => 1} = Jason.decode!(encoded)

      assert %{"b" => 2} = Filters.parse_json("{\"b\":2}")
      assert nil == Filters.parse_json("invalid-json")
    end
  end

  describe "type conversions" do
    test "converts to int, float, string, and boolean" do
      assert Filters.to_int("42") == 42
      assert Filters.to_float("1.5") == 1.5
      assert Filters.to_string(%{"a" => 1}) |> Jason.decode!() == %{"a" => 1}
      assert Filters.to_bool("false") == false
    end
  end

  describe "data manipulation" do
    test "dig plucks nested values across maps and lists" do
      assert Filters.dig(%{"a" => %{"b" => 1}}, "a.b") == 1
      assert Filters.dig([%{"id" => 1}, %{"id" => 2}], "1.id") == 2
    end

    test "pluck, where_eq, and unique_by filter collections" do
      items = [%{"id" => 1, "status" => "active"}, %{"id" => 2, "status" => "active"}]

      assert Filters.pluck(items, "id") == [1, 2]
      assert Filters.where_eq(items, "status", "active") == items
      assert Filters.unique_by(items ++ items, "id") == items
    end

    test "index_by maps items by a field" do
      items = [%{"id" => 1, "name" => "Ada"}, %{"id" => 2, "name" => "Lin"}]
      indexed = Filters.index_by(items, "id")

      assert indexed[1]["name"] == "Ada"
      assert indexed[2]["name"] == "Lin"
    end
  end

  describe "string operations" do
    test "slugify, truncate_words, extract, match, and padding" do
      assert Filters.slugify("Hello, World!") == "hello-world"
      assert Filters.truncate_words("one two three", 2) == "one two..."
      assert Filters.extract("abc123", "\\d+") == "123"
      assert Filters.match("123", "^\\d+$")
      assert Filters.pad_left("7", 3, "0") == "007"
      assert Filters.pad_right("hi", 4) == "hi  "
    end
  end

  describe "math" do
    test "supports common math helpers" do
      assert Filters.abs(-5) == 5
      assert Filters.ceil(1.2) == 2
      assert Filters.floor(1.8) == 1
      assert Filters.round_to(1.234, 2) == 1.23
      assert Filters.clamp(5, 1, 4) == 4.0
    end
  end

  describe "date/time" do
    test "formats and offsets ISO-8601 date strings" do
      assert Filters.format_date("2024-01-02T03:04:05Z", "%Y-%m-%d") == "2024-01-02"

      shifted = Filters.add_days("2024-01-02T00:00:00Z", 2)
      assert String.starts_with?(shifted, "2024-01-04")
    end
  end

  describe "defaults" do
    test "default and coalesce fallbacks" do
      assert Filters.default("", "N/A") == "N/A"
      assert Filters.coalesce(nil, "fallback") == "fallback"
    end
  end
end
