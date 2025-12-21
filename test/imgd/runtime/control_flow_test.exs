defmodule Imgd.Runtime.ControlFlowTest do
  @moduledoc """
  Tests for control flow primitives: branching, merging, and collection processing.
  """
  use Imgd.DataCase, async: true

  alias Imgd.Runtime.{Token, Item}
  alias Imgd.Nodes.Executors.{Branch, Switch, Merge, SplitItems, AggregateItems}
  alias Imgd.Executions.Execution

  # Helper to create a minimal execution for tests
  defp mock_execution do
    %Execution{
      id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      status: :running,
      trigger: %Execution.Trigger{type: :manual, data: %{}}
    }
  end

  describe "Token" do
    test "wrap/unwrap preserves data" do
      data = %{"name" => "test", "count" => 42}
      token = Token.wrap(data)

      assert token.data == data
      assert token.route == "main"
      assert Token.unwrap(token) == data
    end

    test "with_items creates items token" do
      items = [%{"id" => 1}, %{"id" => 2}]
      token = Token.with_items(items)

      assert Token.has_items?(token)
      assert length(token.items) == 2
      assert Enum.at(token.items, 0).json == %{"id" => 1}
      assert Enum.at(token.items, 0).index == 0
    end

    test "skip creates skip token" do
      token = Token.skip("branch_inactive", source_node_id: "node_1")

      assert Token.skipped?(token)
      assert token.metadata.skip_reason == "branch_inactive"
    end

    test "with_source adds lineage" do
      token = Token.new(%{})
      token = Token.with_source(token, "node_1")
      token = Token.with_source(token, "node_2")

      assert token.lineage == ["node_1", "node_2"]
      assert token.source_node_id == "node_2"
    end
  end

  describe "Item" do
    test "new creates item with index" do
      item = Item.new(%{"name" => "Alice"}, 0)

      assert item.json == %{"name" => "Alice"}
      assert item.index == 0
      assert item.metadata == %{}
    end

    test "new wraps non-map values" do
      item = Item.new("hello", 5)

      assert item.json == %{"value" => "hello"}
      assert item.index == 5
    end

    test "from_list creates indexed items" do
      items = Item.from_list([%{"a" => 1}, %{"b" => 2}, %{"c" => 3}])

      assert length(items) == 3
      assert Enum.at(items, 0).index == 0
      assert Enum.at(items, 2).json == %{"c" => 3}
    end

    test "with_error marks item as failed" do
      item = Item.new(%{"id" => 1}, 0)
      failed = Item.with_error(item, "timeout")

      assert Item.failed?(failed)
      assert failed.metadata.error == "timeout"
    end

    test "get retrieves nested values" do
      item = Item.new(%{"user" => %{"profile" => %{"name" => "Bob"}}}, 0)

      assert Item.get(item, "user.profile.name") == "Bob"
      assert Item.get(item, "missing", "default") == "default"
    end
  end

  describe "Branch executor" do
    test "routes to true branch when condition is truthy" do
      config = %{"condition" => "{{ json.status >= 400 }}"}
      input = %{"status" => 500, "message" => "Error"}

      {:ok, token} = Branch.execute(config, input, mock_execution())

      assert token.route == "true"
      assert token.data == input
    end

    test "routes to false branch when condition is falsy" do
      config = %{"condition" => "{{ json.status >= 400 }}"}
      input = %{"status" => 200, "data" => "ok"}

      {:ok, token} = Branch.execute(config, input, mock_execution())

      assert token.route == "false"
      assert token.data == input
    end

    test "respects pass_data: false" do
      config = %{"condition" => "{{ json.flag }}", "pass_data" => false}
      input = %{"flag" => true, "secret" => "hidden"}

      {:ok, token} = Branch.execute(config, input, mock_execution())

      assert token.route == "true"
      assert token.data == %{}
    end

    test "handles expression syntax variations" do
      # Without {{ }}
      config = %{"condition" => "json.active"}
      input = %{"active" => true}

      {:ok, token} = Branch.execute(config, input, mock_execution())
      assert token.route == "true"
    end
  end

  describe "Switch executor" do
    test "matches exact value" do
      config = %{
        "value" => "{{ json.type }}",
        "cases" => [
          %{"match" => "error", "output" => "error_path"},
          %{"match" => "warning", "output" => "warning_path"}
        ],
        "default_output" => "other"
      }

      input = %{"type" => "error", "message" => "Something broke"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "error_path"

      input = %{"type" => "warning"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "warning_path"

      input = %{"type" => "info"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "other"
    end

    test "supports contains mode" do
      config = %{
        "value" => "{{ json.message }}",
        "mode" => "contains",
        "cases" => [
          %{"match" => "ERROR", "output" => "error"}
        ],
        "default_output" => "ok"
      }

      input = %{"message" => "System ERROR: disk full"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "error"
    end

    test "supports regex mode" do
      config = %{
        "value" => "{{ json.code }}",
        "mode" => "regex",
        "cases" => [
          %{"match" => "^4\\d{2}$", "output" => "client_error"},
          %{"match" => "^5\\d{2}$", "output" => "server_error"}
        ],
        "default_output" => "ok"
      }

      input = %{"code" => "404"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "client_error"

      input = %{"code" => "503"}
      {:ok, token} = Switch.execute(config, input, mock_execution())
      assert token.route == "server_error"
    end
  end

  describe "Merge executor" do
    test "wait_any takes first non-nil result" do
      config = %{"mode" => "wait_any"}

      input = %{
        "branch_1" => Token.skip("inactive"),
        "branch_2" => %{"data" => "from_active_branch"}
      }

      {:ok, result} = Merge.execute(config, input, mock_execution())
      assert result == %{"data" => "from_active_branch"}
    end

    test "wait_all with merge strategy deep merges" do
      config = %{"mode" => "wait_all", "combine_strategy" => "merge"}

      input = %{
        "node_1" => %{"user" => %{"name" => "Alice"}},
        "node_2" => %{"user" => %{"email" => "alice@example.com"}, "meta" => %{}}
      }

      {:ok, result} = Merge.execute(config, input, mock_execution())
      assert result["user"]["name"] == "Alice"
      assert result["user"]["email"] == "alice@example.com"
      assert result["meta"] == %{}
    end

    test "wait_all with append strategy concatenates" do
      config = %{"mode" => "wait_all", "combine_strategy" => "append"}

      input = %{
        "api_1" => [%{"id" => 1}],
        "api_2" => [%{"id" => 2}, %{"id" => 3}]
      }

      {:ok, result} = Merge.execute(config, input, mock_execution())
      assert length(result) == 3
    end

    test "combine with object strategy preserves parent IDs" do
      config = %{"mode" => "combine", "combine_strategy" => "object"}

      input = %{
        "source_a" => %{"status" => "ok"},
        "source_b" => %{"status" => "pending"}
      }

      {:ok, result} = Merge.execute(config, input, mock_execution())
      assert result["source_a"]["status"] == "ok"
      assert result["source_b"]["status"] == "pending"
    end
  end

  describe "SplitItems executor" do
    test "splits array field into items" do
      config = %{"field" => "{{ json.users }}"}

      input = %{
        "users" => [
          %{"name" => "Alice", "age" => 30},
          %{"name" => "Bob", "age" => 25}
        ]
      }

      {:ok, token} = SplitItems.execute(config, input, mock_execution())

      assert Token.has_items?(token)
      assert length(token.items) == 2
      assert Enum.at(token.items, 0).json == %{"name" => "Alice", "age" => 30}
      assert Enum.at(token.items, 1).index == 1
    end

    test "includes parent data when configured" do
      config = %{"field" => "{{ json.items }}", "include_parent" => true}

      input = %{
        "source" => "api",
        "items" => [%{"id" => 1}, %{"id" => 2}]
      }

      {:ok, token} = SplitItems.execute(config, input, mock_execution())

      # Each item should have parent's "source" field
      assert Enum.at(token.items, 0).json["source"] == "api"
      assert Enum.at(token.items, 0).json["id"] == 1
    end

    test "adds key field when configured" do
      config = %{"field" => "{{ json.values }}", "key_field" => "_index"}

      input = %{"values" => ["a", "b", "c"]}

      {:ok, token} = SplitItems.execute(config, input, mock_execution())

      assert Enum.at(token.items, 0).json["_index"] == 0
      assert Enum.at(token.items, 2).json["_index"] == 2
    end
  end

  describe "AggregateItems executor" do
    test "array mode collects all items" do
      config = %{"mode" => "array"}

      items = [
        Item.new(%{"id" => 1, "value" => 10}, 0),
        Item.new(%{"id" => 2, "value" => 20}, 1)
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())

      assert is_list(result)
      assert length(result) == 2
    end

    test "first mode takes first item" do
      config = %{"mode" => "first"}

      items = [
        Item.new(%{"position" => "first"}, 0),
        Item.new(%{"position" => "second"}, 1)
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())
      assert result["position"] == "first"
    end

    test "group_by mode groups items" do
      config = %{"mode" => "group_by", "group_field" => "category"}

      items = [
        Item.new(%{"category" => "A", "value" => 1}, 0),
        Item.new(%{"category" => "B", "value" => 2}, 1),
        Item.new(%{"category" => "A", "value" => 3}, 2)
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())

      assert length(result["A"]) == 2
      assert length(result["B"]) == 1
    end

    test "summarize mode computes statistics" do
      config = %{
        "mode" => "summarize",
        "field" => "amount",
        "operations" => ["count", "sum", "avg", "min", "max"]
      }

      items = [
        Item.new(%{"amount" => 10}, 0),
        Item.new(%{"amount" => 20}, 1),
        Item.new(%{"amount" => 30}, 2)
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())

      assert result["count"] == 3
      assert result["sum"] == 60
      assert result["avg"] == 20.0
      assert result["min"] == 10
      assert result["max"] == 30
    end

    test "excludes failed items by default" do
      config = %{"mode" => "array"}

      items = [
        Item.new(%{"id" => 1}, 0),
        Item.new(%{"id" => 2}, 1) |> Item.with_error("timeout"),
        Item.new(%{"id" => 3}, 2)
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())

      assert length(result) == 2
      assert Enum.find(result, &(&1["id"] == 2)) == nil
    end

    test "includes failed items when configured" do
      config = %{"mode" => "array", "include_errors" => true}

      items = [
        Item.new(%{"id" => 1}, 0),
        Item.new(%{"id" => 2}, 1) |> Item.with_error("timeout")
      ]

      input = Token.with_items(items)

      {:ok, result} = AggregateItems.execute(config, input, mock_execution())

      assert length(result) == 2
    end
  end

  describe "validation" do
    test "Branch validates condition is required" do
      assert {:error, errors} = Branch.validate_config(%{})
      assert Keyword.has_key?(errors, :condition)
    end

    test "Switch validates value and cases required" do
      assert {:error, errors} = Switch.validate_config(%{})
      assert Keyword.has_key?(errors, :value)
      assert Keyword.has_key?(errors, :cases)
    end

    test "SplitItems validates field is required" do
      assert {:error, errors} = SplitItems.validate_config(%{})
      assert Keyword.has_key?(errors, :field)
    end

    test "AggregateItems validates group_field for group_by mode" do
      assert {:error, errors} = AggregateItems.validate_config(%{"mode" => "group_by"})
      assert Keyword.has_key?(errors, :group_field)
    end
  end
end
