defmodule ImgdWeb.Formatters do
  @moduledoc """
  View helpers for formatting data across the UI.
  """

  alias Imgd.Workflows.Workflow

  def formatted_timestamp(nil), do: "moments ago"

  def formatted_timestamp(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y at %H:%M")
  end

  def trigger_label(%Workflow{trigger_config: %{"type" => type}}), do: format_trigger(type)
  def trigger_label(%Workflow{trigger_config: %{type: type}}), do: format_trigger(type)
  def trigger_label(_workflow), do: "Manual"

  def status_badge_class(:draft), do: "badge-warning"
  def status_badge_class(:published), do: "badge-success"
  def status_badge_class(:archived), do: "badge-neutral"
  def status_badge_class(_status), do: "badge-ghost"

  def status_label(:draft), do: "Draft"
  def status_label(:published), do: "Published"
  def status_label(:archived), do: "Archived"
  def status_label(_status), do: "Unknown"

  def short_id(id) do
    id
    |> to_string()
    |> String.slice(0, 8)
    |> Kernel.<>("…")
  end

  defp format_trigger(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
