defmodule Imgd.Runtime.ResourceUsage do
  @moduledoc """
  Helpers for sampling and summarizing process resource usage.
  """

  @type sample :: %{
          sampled_at_ms: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          heap_bytes: non_neg_integer(),
          total_heap_bytes: non_neg_integer(),
          stack_bytes: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          reductions: non_neg_integer()
        }

  @spec sample(pid()) :: sample() | nil
  def sample(pid \\ self()) do
    case Process.info(pid, [
           :memory,
           :reductions,
           :message_queue_len,
           :heap_size,
           :total_heap_size,
           :stack_size
         ]) do
      nil ->
        nil

      info ->
        word_size = :erlang.system_info(:wordsize)
        heap_words = Keyword.get(info, :heap_size, 0)
        total_heap_words = Keyword.get(info, :total_heap_size, 0)
        stack_words = Keyword.get(info, :stack_size, 0)

        %{
          sampled_at_ms: System.system_time(:millisecond),
          memory_bytes: Keyword.get(info, :memory, 0),
          heap_bytes: heap_words * word_size,
          total_heap_bytes: total_heap_words * word_size,
          stack_bytes: stack_words * word_size,
          message_queue_len: Keyword.get(info, :message_queue_len, 0),
          reductions: Keyword.get(info, :reductions, 0)
        }
    end
  end

  @spec with_rate(sample(), sample() | nil) :: map()
  def with_rate(current, previous) when is_map(current) do
    {interval_ms, reductions_delta} =
      case previous do
        %{} ->
          {
            max(current.sampled_at_ms - previous.sampled_at_ms, 0),
            max(current.reductions - previous.reductions, 0)
          }

        _ ->
          {0, 0}
      end

    reductions_per_s =
      if interval_ms > 0 do
        Float.round(reductions_delta * 1_000 / interval_ms, 2)
      else
        0.0
      end

    Map.merge(current, %{
      interval_ms: interval_ms,
      reductions_delta: reductions_delta,
      reductions_per_s: reductions_per_s
    })
  end

  @spec summarize(sample(), sample()) :: map()
  def summarize(start_sample, end_sample)
      when is_map(start_sample) and is_map(end_sample) do
    duration_ms = max(end_sample.sampled_at_ms - start_sample.sampled_at_ms, 0)
    reductions_delta = max(end_sample.reductions - start_sample.reductions, 0)

    reductions_per_s =
      if duration_ms > 0 do
        Float.round(reductions_delta * 1_000 / duration_ms, 2)
      else
        0.0
      end

    end_sample
    |> Map.merge(%{
      started_at_ms: start_sample.sampled_at_ms,
      completed_at_ms: end_sample.sampled_at_ms,
      duration_ms: duration_ms,
      reductions_delta: reductions_delta,
      reductions_per_s: reductions_per_s
    })
  end
end
