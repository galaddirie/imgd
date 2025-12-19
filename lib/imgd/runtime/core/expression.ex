defmodule Imgd.Runtime.Core.Expression do
  @moduledoc """
  Pure expression evaluator.
  Wraps Solid (Liquid templates) for usage in NodeRunner.
  """

  alias Imgd.Runtime.Expression.Filters
  alias Imgd.Runtime.Expression.Cache

  @default_timeout_ms 1000

  @type context :: map()
  @type eval_result :: {:ok, term()} | {:error, term()}

  @doc """
  Evaluates a template string or data structure against the provided context.
  """
  @spec evaluate(term(), context(), keyword()) :: eval_result()
  def evaluate(template, context, opts \\ [])

  def evaluate(template, context, opts) when is_binary(template) do
    if contains_expression?(template) do
      do_evaluate_string(template, context, opts)
    else
      {:ok, template}
    end
  end

  def evaluate(data, context, opts) when is_map(data) do
    # Deep evaluation for maps
    try do
      result =
        Map.new(data, fn {k, v} ->
          {k, evaluate!(v, context, opts)}
        end)

      {:ok, result}
    catch
      :throw, {:eval_error, reason} -> {:error, reason}
    end
  end

  def evaluate(data, context, opts) when is_list(data) do
    # Deep evaluation for lists
    try do
      result = Enum.map(data, &evaluate!(&1, context, opts))
      {:ok, result}
    catch
      :throw, {:eval_error, reason} -> {:error, reason}
    end
  end

  def evaluate(other, _context, _opts), do: {:ok, other}

  defp evaluate!(item, context, opts) do
    case evaluate(item, context, opts) do
      {:ok, res} -> res
      {:error, reason} -> throw({:eval_error, reason})
    end
  end

  defp contains_expression?(str), do: String.contains?(str, "{{") or String.contains?(str, "{%")

  defp do_evaluate_string(template, context, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    # For simple templates (just variable interpolation), skip Task overhead entirely
    if simple_template?(template) do
      with {:ok, compiled} <- Cache.get_or_compile(template) do
        render(compiled, context)
      end
    else
      # Only wrap complex templates in Task for timeout protection
      task =
        Task.async(fn ->
          with {:ok, compiled} <- Cache.get_or_compile(template) do
            render(compiled, context)
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, reason} -> {:error, reason}
      end
    end
  end

  # Simple templates = no loops, no complex logic, just variable interpolation
  defp simple_template?(template) do
    not String.contains?(template, "{%")
  end

  defp render(compiled, context) do
    # Reusing existing Filters
    render_opts = [
      custom_filters: Filters,
      strict_variables: false,
      strict_filters: true
    ]

    case Solid.render(compiled, context, render_opts) do
      {:ok, iodata} ->
        {:ok, IO.iodata_to_binary(iodata)}

      {:ok, iodata, _warnings} ->
        {:ok, IO.iodata_to_binary(iodata)}

      {:error, errors, _} ->
        {:error, errors}
    end
  end
end
