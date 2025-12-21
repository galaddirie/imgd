defmodule Imgd.Nodes.Executors.Merge do
  @moduledoc """
  Executor for Merge nodes.

  Combines multiple branch paths back into a single execution stream.
  Essential for rejoining after Branch or Switch nodes.

  ## Join Modes

  - `wait_any` (default) - Execute when ANY parent completes (first wins)
  - `wait_all` - Execute when ALL parents complete, combine results
  - `combine` - Collect all parent outputs into an array

  ## Configuration

  - `mode` - Join mode (default: "wait_any")
  - `combine_strategy` - How to combine in wait_all/combine modes

  ## Combine Strategies

  - `first` - Use first non-nil result (for wait_any)
  - `merge` - Deep merge objects (for wait_all with objects)
  - `append` - Concatenate arrays/items
  - `object` - Create object keyed by parent node ID

  ## Example

      # Simple merge after if/else
      %{"mode" => "wait_any"}

      # Combine multiple API responses
      %{
        "mode" => "wait_all",
        "combine_strategy" => "append"
      }
  """

  use Imgd.Nodes.Definition,
    id: "merge",
    name: "Merge",
    category: "Control Flow",
    description: "Combine multiple branches into one path",
    icon: "hero-arrows-pointing-in",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "mode" => %{
        "type" => "string",
        "title" => "Join Mode",
        "enum" => ["wait_any", "wait_all", "combine"],
        "default" => "wait_any",
        "description" => "When to execute: on first parent, or after all parents"
      },
      "combine_strategy" => %{
        "type" => "string",
        "title" => "Combine Strategy",
        "enum" => ["first", "merge", "append", "object"],
        "default" => "first",
        "description" => "How to combine parent outputs"
      }
    }
  }

  @input_schema %{
    "type" => "object",
    "description" => "Receives data from multiple parent branches"
  }

  @output_schema %{
    "type" => "object",
    "description" => "Combined output based on mode and strategy"
  }

  @behaviour Imgd.Nodes.Executors.Behaviour

  alias Imgd.Runtime.Token

  @doc """
  Special metadata flag indicating this node has multi-parent join semantics.
  The runtime uses this to handle input gathering differently.
  """
  def join_mode, do: true

  @impl true
  def execute(config, input, _execution) do
    mode = Map.get(config, "mode", "wait_any")
    strategy = Map.get(config, "combine_strategy", "first")

    # Input comes as a map of parent_id => result
    # Some entries may be skipped tokens
    result = combine_inputs(input, mode, strategy)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "mode") do
        nil -> errors
        m when m in ["wait_any", "wait_all", "combine"] -> errors
        _ -> [{:mode, "must be wait_any, wait_all, or combine"} | errors]
      end

    errors =
      case Map.get(config, "combine_strategy") do
        nil -> errors
        s when s in ["first", "merge", "append", "object"] -> errors
        _ -> [{:combine_strategy, "must be first, merge, append, or object"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp combine_inputs(input, mode, strategy) when is_map(input) do
    # Separate active and skipped inputs
    {active, _skipped} =
      Enum.split_with(input, fn {_parent_id, value} ->
        not is_skipped?(value)
      end)

    active_values = Enum.map(active, fn {_id, v} -> unwrap_value(v) end)
    active_with_ids = Enum.into(active, %{}, fn {id, v} -> {id, unwrap_value(v)} end)

    case {mode, strategy, active_values} do
      # No active parents - return nil or skip
      {_, _, []} ->
        nil

      # Wait any - just take the first non-nil
      {"wait_any", _, values} ->
        Enum.find(values, & &1)

      # Wait all with first strategy
      {"wait_all", "first", [first | _]} ->
        first

      # Wait all with merge strategy
      {"wait_all", "merge", values} ->
        deep_merge_all(values)

      # Wait all with append strategy
      {"wait_all", "append", values} ->
        append_all(values)

      # Wait all with object strategy - keep parent IDs
      {"wait_all", "object", _} ->
        active_with_ids

      # Combine mode - always collect
      {"combine", "append", values} ->
        append_all(values)

      {"combine", "object", _} ->
        active_with_ids

      {"combine", _, values} ->
        values
    end
  end

  # Single value input (shouldn't happen for merge, but handle gracefully)
  defp combine_inputs(input, _mode, _strategy) do
    unwrap_value(input)
  end

  defp is_skipped?(%Token{} = token), do: Token.skipped?(token)
  defp is_skipped?(%{metadata: %{skipped: true}}), do: true
  defp is_skipped?(_), do: false

  defp unwrap_value(%Token{} = token), do: Token.unwrap(token)
  defp unwrap_value(value), do: value

  defp deep_merge_all(values) do
    Enum.reduce(values, %{}, fn
      value, acc when is_map(value) -> deep_merge(acc, value)
      _value, acc -> acc
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, l, r when is_map(l) and is_map(r) -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp deep_merge(_left, right), do: right

  defp append_all(values) do
    Enum.reduce(values, [], fn
      value, acc when is_list(value) -> acc ++ value
      value, acc -> acc ++ [value]
    end)
  end
end
