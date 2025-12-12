defmodule Imgd.Sandbox.Config do
  @moduledoc false

  @enforce_keys [:timeout, :args, :fuel, :memory_mb, :max_output_size, :max_code_size, :quickjs_wasm_path]
  defstruct [:timeout, :args, :fuel, :memory_mb, :max_output_size, :max_code_size, :quickjs_wasm_path]

  @type t :: %__MODULE__{
          timeout: pos_integer(),
          args: map(),
          fuel: pos_integer(),
          memory_mb: pos_integer(),
          max_output_size: pos_integer(),
          max_code_size: pos_integer(),
          quickjs_wasm_path: String.t()
        }

  @defaults [
    timeout: 5_000,
    args: %{},
    fuel: 10_000_000,
    memory_mb: 16,
    max_output_size: 1_048_576,
    max_code_size: 102_400
  ]

  @spec build(Keyword.t()) :: t()
  def build(opts) when is_list(opts) do
    app_config = Application.get_env(:imgd, Imgd.Sandbox, [])

    merged =
      @defaults
      |> Keyword.merge(app_config)
      |> Keyword.merge(opts)

    struct!(__MODULE__, merged)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = config) do
    with :ok <- validate_pos_int(config.timeout, "timeout"),
         :ok <- validate_pos_int(config.fuel, "fuel"),
         :ok <- validate_pos_int(config.memory_mb, "memory_mb"),
         :ok <- validate_pos_int(config.max_output_size, "max_output_size"),
         :ok <- validate_pos_int(config.max_code_size, "max_code_size") do
      :ok
    end
  end

  defp validate_pos_int(value, name) when is_integer(value) and value > 0, do: :ok

  defp validate_pos_int(_value, name),
    do: {:error, {:validation_error, "#{name} must be a positive integer"}}
end
