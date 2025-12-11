efmodule Imgd.Utils.Expression do
  @moduledoc """
  Handles expression evaluation for data flow between nodes.

  Supports n8n-style expressions:
  - {{ $json.field }}           - Current input data
  - {{ $node["HTTP"].json }}    - Output from specific node
  - {{ $execution.id }}         - Execution metadata
  - {{ $credentials.openai.api_key }}   - Credentials
  - {{ $variables.name }}        - Workflow variables
  - {{ $metadata.trace_id }}    - Execution metadata
  - {{ $if(condition, a, b) }}  - Conditionals

  Expressions can appear in node configs and are resolved at runtime.
  """

  alias Imgd.Executions.Context

  @expression_pattern ~r/\{\{\s*(.+?)\s*\}\}/

  # TODO implement this

  # todo: does this need to be a separate module? does this belong in executions?
end
