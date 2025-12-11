defmodule Imgd.Nodes.Type do
  @moduledoc """
  A Node Type is a template/blueprint for nodes users can add to workflows.

  Examples: "HTTP Request", "Transform", "Postgres Query", "If/Else", etc.

  Each type defines:
  - Configuration schema (what the user configures in the UI)
  - Input/Output schemas (for validation and UI hints)
  - An executor module that implements the actual logic

  ## Usage

  Node types are defined using `Imgd.Nodes.Definition` in executor modules
  and registered in `Imgd.Nodes.Registry` at startup.

  To get a node type:

      {:ok, type} = Imgd.Nodes.Registry.get("http_request")

  To list all types:

      types = Imgd.Nodes.Registry.all()
  """

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

  @enforce_keys [:id, :name, :category, :description, :icon, :executor, :node_kind]
  defstruct [
    :id,
    :name,
    :category,
    :description,
    :icon,
    :executor,
    :node_kind,
    :inserted_at,
    :updated_at,
    config_schema: %{},
    input_schema: %{},
    output_schema: %{}
  ]

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
  Converts the executor string to a module atom or raises.
  """
  def executor_module!(%__MODULE__{} = type) do
    case executor_module(type) do
      {:ok, module} -> module
      {:error, reason} -> raise "Failed to get executor module: #{inspect(reason)}"
    end
  end

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

  @doc """
  Returns true if this is an action node type.
  """
  def action?(%__MODULE__{node_kind: :action}), do: true
  def action?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is a transform node type.
  """
  def transform?(%__MODULE__{node_kind: :transform}), do: true
  def transform?(%__MODULE__{}), do: false
end
