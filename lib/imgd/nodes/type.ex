defmodule Imgd.Nodes.Type do
  @moduledoc """
  A Node Type is a template/blueprint for nodes users can add to workflows.

  Examples: "HTTP Request", "Transform", "Postgres Query", "If/Else", etc.

  Each type defines:
  - Configuration schema (what the user configures in the UI)
  - Input/Output schemas (for validation and UI hints)
  - An executor module that implements the actual logic
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Imgd.ChangesetHelpers

  @type node_kind :: :action | :trigger | :control_flow | :transform

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          category: String.t(),
          description: String.t(),
          icon: String.t(),
          config_schema: map(),
          input_schema: map(),
          output_schema: map(),
          executor: String.t(),
          node_kind: node_kind(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  embedded_schema do
    field :name, :string
    field :category, :string
    field :description, :string
    field :icon, :string

    # JSON Schema definitions
    field :config_schema, :map, default: %{}
    field :input_schema, :map, default: %{}
    field :output_schema, :map, default: %{}

    # Module name as string (e.g., "Imgd.Nodes.Executors.HTTP")
    field :executor, :string

    field :node_kind, Ecto.Enum, values: [:action, :trigger, :control_flow, :transform]

    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(node_type, attrs) do
    node_type
    |> cast(attrs, [
      :id,
      :name,
      :category,
      :description,
      :icon,
      :config_schema,
      :input_schema,
      :output_schema,
      :executor,
      :node_kind
    ])
    |> validate_required([
      :id,
      :name,
      :category,
      :description,
      :executor,
      :node_kind
    ])
    |> validate_map_field(:config_schema)
    |> validate_map_field(:input_schema)
    |> validate_map_field(:output_schema)
    |> validate_executor()
  end

  defp validate_executor(changeset) do
    validate_change(changeset, :executor, fn :executor, value ->
      cond do
        not is_binary(value) ->
          [executor: "must be a string"]

        not String.starts_with?(value, "Elixir.") and not String.contains?(value, ".") ->
          [executor: "must be a valid module name (e.g., Imgd.Nodes.Executors.HTTP)"]

        true ->
          []
      end
    end)
  end

  @doc """
  Converts the executor string to a module atom.
  Returns `{:ok, module}` or `{:error, reason}`.
  """
  def executor_module(%__MODULE__{executor: executor}) when is_binary(executor) do
    module =
      if String.starts_with?(executor, "Elixir.") do
        String.to_existing_atom(executor)
      else
        String.to_existing_atom("Elixir." <> executor)
      end

    {:ok, module}
  rescue
    ArgumentError -> {:error, :module_not_loaded}
  end

  def executor_module(%__MODULE__{executor: nil}), do: {:error, :no_executor}

  @doc """
  Returns true if this is a trigger node type.
  """
  def trigger?(%__MODULE__{node_kind: :trigger}), do: true
  def trigger?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is a control flow node type (if/else, switch, loop, etc.).
  """
  def control_flow?(%__MODULE__{node_kind: :control_flow}), do: true
  def control_flow?(%__MODULE__{}), do: false
end
