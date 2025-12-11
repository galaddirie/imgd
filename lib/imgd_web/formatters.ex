defmodule ImgdWeb.Formatters do
  @moduledoc """
  Shared formatting helpers for LiveViews and templates.
  """

  @doc """
  Formats a timestamp for display.
  """
  def formatted_timestamp(nil), do: "-"

  def formatted_timestamp(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %H:%M")
  end

  @doc """
  Returns a shortened ID for display.
  """
  def short_id(nil), do: "-"

  def short_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  @doc """
  Returns the CSS class for a workflow status badge.
  """
  def status_badge_class(:draft), do: "badge-warning"
  def status_badge_class(:active), do: "badge-success"
  def status_badge_class(:archived), do: "badge-neutral"
  def status_badge_class(_), do: "badge-ghost"

  @doc """
  Returns a human-readable label for a workflow status.
  """
  def status_label(:draft), do: "Draft"
  def status_label(:active), do: "Published"
  def status_label(:archived), do: "Archived"
  def status_label(status), do: to_string(status)

  @doc """
  Returns a human-readable label for the workflow trigger type.
  """
  def trigger_label(%{trigger_config: %{"type" => type}}) do
    trigger_type_label(type)
  end

  def trigger_label(%{trigger_config: %{type: type}}) do
    trigger_type_label(type)
  end

  def trigger_label(_), do: "Manual"

  defp trigger_type_label("manual"), do: "Manual"
  defp trigger_type_label(:manual), do: "Manual"
  defp trigger_type_label("schedule"), do: "Scheduled"
  defp trigger_type_label(:schedule), do: "Scheduled"
  defp trigger_type_label("webhook"), do: "Webhook"
  defp trigger_type_label(:webhook), do: "Webhook"
  defp trigger_type_label("event"), do: "Event"
  defp trigger_type_label(:event), do: "Event"
  defp trigger_type_label(type), do: to_string(type)
end
