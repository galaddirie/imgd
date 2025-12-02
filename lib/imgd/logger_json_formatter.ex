defmodule Imgd.LoggerJSONFormatter do
  @moduledoc """
  Logger formatter that emits flat JSON lines compatible with promtail.
  """

  @spec format(Logger.level(), Logger.message(), Logger.Formatter.time(), Logger.metadata()) ::
          iodata()
  def format(level, message, timestamp, metadata) do
    payload =
      metadata
      |> Map.new()
      |> sanitize()
      |> Map.merge(%{
        time: format_timestamp(timestamp),
        level: Atom.to_string(level),
        message: normalize_message(message)
      })

    Jason.encode_to_iodata!(payload) ++ "\n"
  rescue
    _ ->
      fallback = %{
        time: System.system_time(:second),
        level: Atom.to_string(level),
        message: normalize_message(message),
        metadata: inspect(metadata)
      }

      Jason.encode_to_iodata!(fallback) ++ "\n"
  end

  defp normalize_message({:string, msg}), do: IO.iodata_to_binary(msg)
  defp normalize_message({:report, data}), do: inspect(data)
  defp normalize_message(msg) when is_map(msg), do: inspect(msg)

  defp normalize_message({format, args}) do
    format
    |> :io_lib.format(args)
    |> IO.iodata_to_binary()
  end

  defp normalize_message(msg), do: IO.iodata_to_binary(msg)

  defp format_timestamp({date, time}) do
    {:ok, naive} = NaiveDateTime.from_erl({date, time})
    DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.to_iso8601()
  end

  defp sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp sanitize(%Time{} = t), do: Time.to_iso8601(t)
  defp sanitize(%{} = map), do: Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(value) when is_pid(value), do: inspect(value)
  defp sanitize(value) when is_reference(value), do: inspect(value)
  defp sanitize(value) when is_function(value), do: inspect(value)
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value) when is_number(value) or is_boolean(value), do: value
  defp sanitize(value) when is_binary(value), do: value
  defp sanitize(value), do: inspect(value)
end
