defmodule LlmCore.Agent.ToolDispatch.Event do
  @moduledoc """
  Event struct flowing through the ToolDispatch pipeline.

  Created by `DispatchTools` when it detects a tool call with a registered
  dispatch recipe. Carries all context needed for dispatch orchestration.

  ## Fields

  ### Input — set by DispatchTools before pipeline entry

    * `call` — The original `%Call{}` that triggered dispatch
    * `resolve_fn` — Function to execute individual tool calls
    * `recipe` — Recipe function or `nil` for passthrough

  ### Pipeline state — populated by stages

    * `strategy` — `:passthrough` or `:recipe`
    * `plan` — Execution plan from recipe evaluation
    * `serial_results` — Results from serial step execution
    * `serial_context` — Accumulated context from serial results
    * `current_step` — Current parallel step being executed
    * `total_parallel` — Total number of parallel steps expected
    * `step_result` — Result of the current parallel step
    * `parallel_results` — Collected parallel step results
    * `errors` — Accumulated errors from any failed steps

  ### Output — read by DispatchTools after pipeline exit

    * `result` — Final composed string result
    * `status` — `:ok` or `:error`
    * `error` — Error detail when `status == :error`
  """

  alias LlmToolkit.Tool.Call

  @type t :: %__MODULE__{
          call: Call.t() | nil,
          resolve_fn: (Call.t() -> {:ok, String.t()} | {:error, String.t()}) | nil,
          recipe: (map() -> map()) | nil,
          strategy: :passthrough | :recipe,
          plan: map() | nil,
          serial_results: [map()],
          serial_context: map(),
          current_step: map() | nil,
          total_parallel: non_neg_integer(),
          step_result: map() | nil,
          parallel_results: [map()],
          errors: [map()],
          result: String.t() | nil,
          status: :ok | :error,
          error: term() | nil
        }

  defstruct [
    :call,
    :resolve_fn,
    :recipe,
    :current_step,
    :step_result,
    :plan,
    :result,
    :error,
    strategy: :passthrough,
    serial_results: [],
    serial_context: %{},
    total_parallel: 0,
    parallel_results: [],
    errors: [],
    status: :ok
  ]
end
