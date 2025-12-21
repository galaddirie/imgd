defmodule Imgd.Runtime.Execution.MapExecutor do
  @moduledoc """
  Handles parallel execution of nodes in map mode.

  When a node has `execution_mode: :map`, this module:
  1. Extracts items from the input token
  2. Executes the node once per item (respecting batch_size)
  3. Collects results back into an output token

  ## Concurrency Control

  - `batch_size: nil` - Unlimited parallelism (Task.async_stream defaults)
  - `batch_size: N` - Max N concurrent executions

  ## Error Handling

  - By default, failed items are marked with errors but don't fail the whole node
  - The output token includes both successful and failed items
  - Downstream aggregation can choose to include/exclude failed items

  ## Usage

  Called by the execution server when spawning a map-mode node:

      case MapExecutor.execute(node, input_token, context_fun, execution) do
        {:ok, output_token} -> # Token with processed items
        {:error, reason} -> # Complete failure (not item-level)
      end
  """

  require Logger

  alias Imgd.Runtime.{Token, Item}
  alias Imgd.Runtime.Core.NodeRunner
  alias Imgd.Workflows.Embeds.Node
  alias Imgd.Executions.Execution

  @type result :: {:ok, Token.t()} | {:error, term()}

  @default_timeout 30_000
  @default_max_concurrency 10

  @doc """
  Executes a node in map mode, processing each item in parallel.

  ## Options

  Options are derived from the node configuration:
  - batch_size from node.batch_size
  - timeout from node.config["timeout_ms"] or default

  ## Returns

  - `{:ok, token}` - Token containing processed items (may include failed items)
  - `{:error, reason}` - Complete failure (e.g., no items, setup error)
  """
  @spec execute(Node.t(), Token.t() | term(), (-> map()), Execution.t()) :: result()
  def execute(%Node{execution_mode: :map} = node, input, context_fun, %Execution{} = execution) do
    items = Token.to_items(Token.wrap(input))

    if Enum.empty?(items) do
      {:ok, Token.with_items([])}
    else
      batch_size = node.batch_size || @default_max_concurrency
      timeout = get_timeout(node)

      results = execute_items(node, items, context_fun, execution, batch_size, timeout)
      output_token = build_output_token(results)

      {:ok, output_token}
    end
  end

  def execute(%Node{} = node, _input, _context_fun, _execution) do
    {:error, {:not_map_mode, node.id}}
  end

  @doc """
  Executes items in batches with controlled concurrency.
  """
  @spec execute_items(
          Node.t(),
          [Item.t()],
          (-> map()),
          Execution.t(),
          pos_integer(),
          pos_integer()
        ) ::
          [{:ok, Item.t()} | {:error, Item.t()}]
  def execute_items(node, items, context_fun, execution, batch_size, timeout) do
    # Build context once (shared across all items)
    base_context = context_fun.()

    items
    |> Task.async_stream(
      fn item ->
        execute_single_item(node, item, base_context, execution)
      end,
      max_concurrency: batch_size,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end)
    |> Enum.zip(items)
    |> Enum.map(fn {result, original_item} ->
      case result do
        {:ok, output} ->
          {:ok, update_item_with_output(original_item, output)}

        {:error, reason} ->
          {:error, Item.with_error(original_item, reason)}

        {:skip, reason} ->
          {:skip, Item.with_metadata(original_item, %{skipped: true, reason: reason})}
      end
    end)
  end

  # Executes a single item through the node.
  defp execute_single_item(node, %Item{} = item, base_context, execution) do
    # Build item-specific context
    context = build_item_context(base_context, item)

    # Run the node with item's json as input
    NodeRunner.run(node, item.json, context, execution)
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason ->
      {:error, {:caught, kind, reason}}
  end

  # Builds the expression context for a single item.
  defp build_item_context(base_context, %Item{} = item) do
    base_context
    |> Map.put("json", item.json)
    |> Map.put("item", %{
      "json" => item.json,
      "index" => item.index,
      "metadata" => item.metadata
    })
  end

  # Updates an item with the node's output.
  defp update_item_with_output(%Item{} = item, output) when is_map(output) do
    Item.update(item, output)
  end

  defp update_item_with_output(%Item{} = item, output) do
    Item.update(item, %{"value" => output})
  end

  # Builds the output token from processed items.
  defp build_output_token(results) do
    {successful, failed, skipped} = categorize_results(results)

    # Create items list preserving original order
    all_items =
      results
      |> Enum.map(fn
        {:ok, item} -> item
        {:error, item} -> item
        {:skip, item} -> item
      end)

    metadata = %{
      total: length(results),
      successful: length(successful),
      failed: length(failed),
      skipped: length(skipped)
    }

    Token.with_items(all_items, metadata: metadata)
  end

  defp categorize_results(results) do
    results
    |> Enum.reduce({[], [], []}, fn
      {:ok, item}, {ok, err, skip} -> {[item | ok], err, skip}
      {:error, item}, {ok, err, skip} -> {ok, [item | err], skip}
      {:skip, item}, {ok, err, skip} -> {ok, err, [item | skip]}
    end)
  end

  defp get_timeout(%Node{config: config}) do
    Map.get(config, "timeout_ms", @default_timeout)
  end
end
