defmodule Imgd.Sandbox.Error do
  @moduledoc "Structured errors for sandbox failures."

  defexception [:type, :message, details: %{}]

  @type error_type ::
          :validation_error
          | :timeout
          | :fuel_exhausted
          | :memory_exceeded
          | :runtime_error
          | :internal_error

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map()
        }

  @impl true
  def message(%__MODULE__{type: type, message: msg}) do
    "[Sandbox.#{format_type(type)}] #{msg}"
  end

  @spec wrap(term()) :: t()
  def wrap({:timeout, ms}) do
    %__MODULE__{
      type: :timeout,
      message: "Execution exceeded #{ms}ms timeout",
      details: %{timeout_ms: ms}
    }
  end

  def wrap(:fuel_exhausted) do
    %__MODULE__{
      type: :fuel_exhausted,
      message: "Script exceeded maximum allowed instructions (possible infinite loop)",
      details: %{}
    }
  end

  def wrap(:memory_exceeded) do
    %__MODULE__{
      type: :memory_exceeded,
      message: "Script exceeded maximum allowed memory",
      details: %{}
    }
  end

  def wrap({:runtime_error, msg}) do
    %__MODULE__{
      type: :runtime_error,
      message: msg,
      details: %{}
    }
  end

  def wrap({:validation_error, msg}) do
    %__MODULE__{
      type: :validation_error,
      message: msg,
      details: %{}
    }
  end

  def wrap({:code_too_large, actual, max}) do
    %__MODULE__{
      type: :validation_error,
      message: "Code size #{actual} exceeds limit of #{max} bytes",
      details: %{actual: actual, max: max}
    }
  end

  def wrap({:invalid_args, reason}) do
    %__MODULE__{
      type: :validation_error,
      message: "Args must be JSON encodable: #{inspect(reason)}",
      details: %{reason: reason}
    }
  end

  def wrap({:wasm_error, reason}) do
    %__MODULE__{
      type: :internal_error,
      message: "WebAssembly error: #{inspect(reason)}",
      details: %{reason: reason}
    }
  end

  def wrap({:invalid_json, output}) do
    %__MODULE__{
      type: :internal_error,
      message: "Invalid JSON output from sandbox",
      details: %{output: output}
    }
  end

  def wrap(other) do
    %__MODULE__{
      type: :internal_error,
      message: "Unexpected error: #{inspect(other)}",
      details: %{raw: other}
    }
  end

  defp format_type(atom), do: atom |> Atom.to_string() |> Macro.camelize()
end
