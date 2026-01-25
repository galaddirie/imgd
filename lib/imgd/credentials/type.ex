defmodule Imgd.Credentials.Type do
  @moduledoc """
  Defines the structure and behaviour for credential types.

  A credential type defines the schema and metadata for a specific kind of credential
  (e.g., "openai", "github_oauth", "api_key").
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          icon: String.t() | map() | nil,
          category: String.t(),
          field_schema: map(),
          # If true, this type is considered "built-in" and generally available.
          # We might use this later if we support dynamic loading of types.
          built_in: boolean()
        }

  defstruct [
    :id,
    :name,
    :description,
    :icon,
    :category,
    :field_schema,
    built_in: true
  ]

  @callback definition() :: t()
end
