defmodule LlmCore.Agent.Context do
  @moduledoc """
  Carries data through the agentic iteration pipeline.

  One `Context` is created per LLM response and flows through all stages
  of the `LlmCore.Agent.Pipeline.Iteration` pipeline. The outer loop
  (`LlmCore.Agent.Loop`) creates this from the LLM response, sends it
  through the pipeline, and reads the `decision` field to determine the
  next action.

  ## Fields

  ### Input — set by the outer loop before pipeline entry

    * `messages` — Current message list (grows each iteration)
    * `tools` — Available tool definitions (`[LlmCore.Tool.t()]`)
    * `response` — The LLM response for this iteration
    * `resolve_tool` — `fn(%Call{}) -> {:ok, String.t()} | {:error, String.t()}`
    * `iteration` — Current iteration count (0-based)
    * `max_iterations` — Hard iteration limit

  ### Intermediate — populated by pipeline stages

    * `tool_calls` — Parsed tool call requests from the response
    * `tool_results` — Results after tool execution
    * `result_messages` — Formatted messages for the next LLM turn
    * `validation_errors` — Errors from call validation

  ### Output — read by the outer loop after pipeline exit

    * `decision` — `{:continue, messages}`, `{:done, response}`, or
      `{:error, reason}`
    * `status` — `:ok` or `:error` (short-circuit flag for stages)
    * `error` — Error detail when `status == :error`
    * `trace` — Accumulated trace entries for observability
  """

  alias LlmCore.LLM.Response
  alias LlmCore.Tool
  alias LlmCore.Tool.Call
  alias LlmCore.Tool.Result

  @type decision ::
          {:continue, [map()]}
          | {:done, Response.t()}
          | {:error, term()}
          | nil

  @type t :: %__MODULE__{
          messages: [map()],
          tools: [Tool.t()],
          response: Response.t() | nil,
          resolve_tool: (Call.t() -> {:ok, String.t()} | {:error, String.t()}) | nil,
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          tool_calls: [Call.t()],
          tool_results: [Result.t()],
          result_messages: [map()],
          validation_errors: [term()],
          decision: decision(),
          status: :ok | :error,
          error: term() | nil,
          trace: [term()]
        }

  defstruct [
    # Input — set by outer loop before pipeline entry
    :response,
    :resolve_tool,
    messages: [],
    tools: [],
    iteration: 0,
    max_iterations: 10,

    # Intermediate — populated by stages
    tool_calls: [],
    tool_results: [],
    result_messages: [],
    validation_errors: [],

    # Output — read by outer loop after pipeline exit
    decision: nil,
    status: :ok,
    error: nil,
    trace: []
  ]
end
