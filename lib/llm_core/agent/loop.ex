defmodule LlmCore.Agent.Loop do
  @moduledoc """
  Agentic tool-calling loop.

  Iterates: call LLM → feed response through the iteration pipeline →
  if the pipeline says `:continue`, append messages and call the LLM again;
  if `:done`, return the final response.

  A no-tool-call response with blank content (`:blank_stop`) is never
  accepted as completion. The loop retries the turn under a separately
  bounded recovery policy (`:max_blank_stops`) and terminates with a
  typed `{:empty_stop, details}` error when blanks repeat (GC-5523).

  The loop owns iteration control and message accumulation. The pipeline
  (`LlmCore.Agent.Pipeline.Iteration`) owns per-iteration processing logic.

  ## Architecture Mirror

  This mirrors the common `reduce_while` iteration pattern:

      GrooveExecutor                     Agent.Loop
      ─────────────                      ──────────
      Enum.reduce_while over steps       Enum.reduce_while over iterations
      execute_step(step, ctx)            llm_send_fn.(messages, opts)
      StepwiseEngine.handle_event(...)   Pipeline.Iteration (ALF)
      {:cont, {:ok, rt, ctx, tokens}}    {:cont, {:ok, state}}
      {:halt, {:error, reason}}          {:halt, {:error, reason}}

  ## Usage

      {:ok, response, messages} =
        LlmCore.Agent.Loop.run(
          [%{role: :user, content: "Research Elixir ALF"}],
          &my_llm_send/2,
          tools: my_tools,
          resolve_tool: &MyResolver.resolve/1,
          max_iterations: 10
        )
  """

  alias LlmCore.Agent.Context
  alias LlmCore.Agent.Pipeline.Iteration, as: IterationPipeline

  @type llm_send_fn ::
          ([map()], keyword() -> {:ok, LlmCore.LLM.Response.t()} | {:error, term()})

  @type opts :: [
          {:tools, [LlmToolkit.Tool.t()]}
          | {:resolve_tool,
             (LlmToolkit.Tool.Call.t() -> {:ok, String.t()} | {:error, String.t()})}
          | {:resolver_module, module() | nil}
          | {:max_iterations, pos_integer()}
          | {:on_iteration, (Context.t() -> :ok) | nil}
          | {:pipeline_opts, keyword()}
          | {:llm_opts, keyword()}
          | {:terminal_tool, String.t() | nil}
          | {:max_blank_stops, pos_integer()}
          | {:blank_stop_nudge, String.t() | nil}
        ]

  @default_max_iterations 10

  # Bounded recovery for degenerate empty-stop responses (GC-5523):
  # a provider returns HTTP success with finish_reason "stop", blank
  # content, and no tool calls while the task is still incomplete.
  # Per iteration, tolerate up to this many consecutive blank stops before
  # terminating with a typed {:empty_stop, details} error. Retries do not
  # consume the normal iteration budget — the two budgets are separate.
  @default_max_blank_stops 3

  # When the same tool error repeats this many times consecutively,
  # break out of the loop — it's a systematic bug, not a transient failure.
  # The model can't fix it by varying arguments.
  @error_repeat_threshold 3

  @doc """
  Runs the agentic loop.

  Calls `llm_send_fn` with the current messages and tool definitions.
  If the LLM responds with tool calls, the response flows through the
  iteration pipeline which dispatches tools, collects results, and
  builds new messages. The loop repeats until the LLM produces a text-only
  response or the iteration budget is exhausted.

  ## Parameters

    * `messages` — Initial message list (system prompt, history, user message)
    * `llm_send_fn` — `fn(messages, opts) -> {:ok, Response.t()} | {:error, term()}`
    * `opts` — Configuration keyword list:
      * `:tools` — (required) list of `LlmToolkit.Tool.t()` definitions
      * `:resolve_tool` — (required) `fn(Call.t()) -> {:ok, string} | {:error, string}`
      * `:resolver_module` — optional module implementing `ToolResolver` behaviour.
        When set, `DispatchTools` checks for dispatch recipes via
        `resolver_module.dispatch_recipe/1`.
      * `:max_iterations` — iteration ceiling (default: #{@default_max_iterations})
      * `:on_iteration` — optional callback invoked with the pipeline context
        after each iteration
      * `:pipeline_opts` — options forwarded to `Pipeline.Iteration.ensure_started/1`
      * `:llm_opts` — extra options forwarded to `llm_send_fn`
      * `:terminal_tool` — optional tool name that stops the loop when called.
        The tool is not dispatched; its raw arguments are attached to
        `response.metadata.terminal_args`, with the call under
        `response.metadata.terminal_tool_call`.
      * `:max_blank_stops` — max consecutive blank-stop responses tolerated
        per iteration before the typed `{:empty_stop, details}` error
        (default: #{@default_max_blank_stops}). Blank-stop retries do not
        consume the iteration budget.
      * `:blank_stop_nudge` — optional user-message text appended to the
        messages before a blank-stop retry, to break a degenerate provider
        mode. When unset (default), the turn is retried with unchanged
        messages.

  ## Returns

    * `{:ok, final_response, final_messages}` — LLM produced a text response
    * `{:error, reason}` — Budget exceeded, LLM error, pipeline error, or
      repeated blank stops (`{:empty_stop, %{iteration:, attempts:,
      finish_reasons:, provider:, model:}}`)

  ## Telemetry

  Emits `[:llm_core, :agent, :complete]` on loop exit with measurements
  `%{total_iterations: N}` and metadata `%{tool_calls_count: N}`.
  """
  @spec run([map()], llm_send_fn(), opts()) ::
          {:ok, LlmCore.LLM.Response.t(), [map()]} | {:error, term()}
  def run(messages, llm_send_fn, opts) do
    tools = Keyword.fetch!(opts, :tools)
    resolve_tool = Keyword.fetch!(opts, :resolve_tool)
    resolver_module = Keyword.get(opts, :resolver_module)
    terminal_tool = Keyword.get(opts, :terminal_tool)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_blank_stops = Keyword.get(opts, :max_blank_stops, @default_max_blank_stops)
    blank_stop_nudge = Keyword.get(opts, :blank_stop_nudge)
    on_iteration = Keyword.get(opts, :on_iteration)
    pipeline_opts = Keyword.get(opts, :pipeline_opts, sync: true)
    llm_opts = [tools: tools] ++ Keyword.get(opts, :llm_opts, [])

    :ok = IterationPipeline.ensure_started(pipeline_opts)

    initial_state = %{
      messages: messages,
      tools: tools,
      resolve_tool: resolve_tool,
      resolver_module: resolver_module,
      terminal_tool: terminal_tool,
      max_iterations: max_iterations,
      max_blank_stops: max_blank_stops,
      blank_stop_nudge: blank_stop_nudge,
      on_iteration: on_iteration,
      total_tool_calls: 0,
      last_error: nil,
      error_repeat_count: 0
    }

    result =
      0..(max_iterations - 1)
      |> Enum.reduce_while({:ok, initial_state}, fn iteration, {:ok, state} ->
        case do_iteration(state, llm_send_fn, llm_opts, iteration) do
          {:continue, new_state} ->
            {:cont, {:ok, new_state}}

          {:done, response, final_messages, total_tool_calls} ->
            {:halt, {:ok, response, final_messages, iteration + 1, total_tool_calls}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, response, final_messages, total_iterations, total_tool_calls} ->
        emit_complete(total_iterations, total_tool_calls)
        {:ok, response, final_messages}

      {:error, reason} ->
        {:error, reason}

      {:ok, state} ->
        emit_complete(max_iterations, state.total_tool_calls)
        {:error, :max_iterations_reached}
    end
  end

  # -- Private ----------------------------------------------------------------

  @spec do_iteration(map(), llm_send_fn(), keyword(), non_neg_integer()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:error, term()}
  defp do_iteration(state, llm_send_fn, llm_opts, iteration) do
    recover_blank_stops(state, llm_send_fn, llm_opts, iteration, %{attempts: 0, finish_reasons: []})
  end

  # Separately bounded blank-stop recovery (GC-5523).
  #
  # A blank stop (no tool calls, blank content) retries the same iteration
  # without consuming the iteration budget. After `max_blank_stops`
  # consecutive blanks the loop terminates with the typed error
  # `{:empty_stop, details}` carrying bounded terminal diagnostics:
  # iteration number, attempt count, and the observed finish reasons.
  @spec recover_blank_stops(map(), llm_send_fn(), keyword(), non_neg_integer(), map()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:error, term()}
  defp recover_blank_stops(state, llm_send_fn, llm_opts, iteration, recovery) do
    case llm_send_fn.(state.messages, llm_opts) do
      {:ok, response} ->
        case process_response(state, response, iteration) do
          {:blank_stop, blank} ->
            attempts = recovery.attempts + 1
            finish_reasons = recovery.finish_reasons ++ [finish_reason(blank)]

            if attempts >= state.max_blank_stops do
              require Logger

              Logger.warning(
                "[Agent.Loop] Empty stop: #{attempts} consecutive blank responses at iteration #{iteration} — terminating"
              )

              {:error,
               {:empty_stop,
                %{
                  iteration: iteration,
                  attempts: attempts,
                  finish_reasons: finish_reasons,
                  provider: blank.provider,
                  model: blank.model
                }}}
            else
              require Logger

              Logger.warning(
                "[Agent.Loop] Blank stop (attempt #{attempts}/#{state.max_blank_stops}) at iteration #{iteration} — retrying"
              )

              state = maybe_push_nudge(state)

              recover_blank_stops(state, llm_send_fn, llm_opts, iteration, %{
                attempts: attempts,
                finish_reasons: finish_reasons
              })
            end

          {:done, response, messages, tool_calls} ->
            if recovery.attempts > 0 do
              {:done, mark_blank_recovery(response, recovery.attempts), messages, tool_calls}
            else
              {:done, response, messages, tool_calls}
            end

          other ->
            other
        end

      {:error, reason} ->
        {:error, {:llm_error, reason}}
    end
  end

  @spec process_response(map(), LlmCore.LLM.Response.t(), non_neg_integer()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:blank_stop, LlmCore.LLM.Response.t()}
          | {:error, term()}
  defp process_response(state, response, iteration) do
    # 2. Build pipeline context
    ctx = %Context{
      response: response,
      messages: state.messages,
      tools: state.tools,
      resolve_tool: state.resolve_tool,
      resolver_module: state.resolver_module,
      terminal_tool: state.terminal_tool,
      iteration: iteration,
      max_iterations: state.max_iterations
    }

    # 3. Feed through iteration pipeline
    pipeline_result =
      ALF.Manager.call(ctx, IterationPipeline, sync: true)

    # 4. Interpret pipeline decision
    handle_pipeline_result(pipeline_result, state)
  end

  @spec handle_pipeline_result(Context.t() | term(), map()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:blank_stop, LlmCore.LLM.Response.t()}
          | {:error, term()}
  defp handle_pipeline_result(%Context{decision: {:done, final_response}} = result_ctx, state) do
    maybe_notify(state.on_iteration, result_ctx)

    {:done, attach_terminal_metadata(final_response, result_ctx), state.messages,
     state.total_tool_calls}
  end

  defp handle_pipeline_result(
         %Context{decision: {:continue, new_messages}} = result_ctx,
         state
       ) do
    maybe_notify(state.on_iteration, result_ctx)
    tool_calls_count = length(result_ctx.tool_calls)

    # Circuit breaker: detect repeated identical tool errors.
    # When the same error message appears N times in a row, the tool has
    # a systematic bug — the model can't fix it by varying arguments.
    error_fingerprint = extract_error_fingerprint(result_ctx.tool_results)
    {last_error, repeat_count} = update_error_tracker(state, error_fingerprint)

    if repeat_count >= @error_repeat_threshold do
      require Logger

      Logger.warning(
        "[Agent.Loop] Circuit breaker: same tool error repeated #{repeat_count}x — breaking loop"
      )

      {:error,
       {:circuit_breaker,
        "Tool error repeated #{@error_repeat_threshold}+ times: #{inspect(last_error)}"}}
    else
      updated_state = %{
        state
        | messages: state.messages ++ new_messages,
          total_tool_calls: state.total_tool_calls + tool_calls_count,
          last_error: last_error,
          error_repeat_count: repeat_count
      }

      {:continue, updated_state}
    end
  end

  defp handle_pipeline_result(%Context{decision: {:blank_stop, response}} = result_ctx, state) do
    maybe_notify(state.on_iteration, result_ctx)
    {:blank_stop, response}
  end

  defp handle_pipeline_result(%Context{decision: {:error, reason}} = result_ctx, state) do
    maybe_notify(state.on_iteration, result_ctx)
    emit_complete(result_ctx.iteration + 1, state.total_tool_calls)
    {:error, reason}
  end

  defp handle_pipeline_result(%ALF.ErrorIP{error: reason}, _state) do
    {:error, {:pipeline_error, reason}}
  end

  defp handle_pipeline_result(other, _state) do
    {:error, {:unexpected_pipeline_result, other}}
  end

  # Extract a fingerprint from tool results — all error messages joined.
  # Returns nil if there are no errors (all tools succeeded).
  defp extract_error_fingerprint(tool_results) when is_list(tool_results) do
    errors =
      tool_results
      |> Enum.filter(fn
        {:error, _} -> true
        %{error: _} -> true
        _ -> false
      end)
      |> Enum.map(fn
        {:error, msg} -> to_string(msg)
        %{error: msg} -> to_string(msg)
      end)

    if errors == [], do: nil, else: Enum.join(errors, " | ")
  end

  defp extract_error_fingerprint(_), do: nil

  # Track consecutive identical error fingerprints.
  # Same error → increment. Different error → reset counter. No error → reset.
  defp update_error_tracker(_state, nil), do: {nil, 0}

  defp update_error_tracker(%{last_error: last, error_repeat_count: count}, fingerprint)
       when fingerprint == last do
    {fingerprint, count + 1}
  end

  defp update_error_tracker(_state, fingerprint) do
    {fingerprint, 1}
  end

  defp attach_terminal_metadata(response, %Context{terminal_tool_call: nil}), do: response

  defp attach_terminal_metadata(response, %Context{} = ctx) do
    metadata =
      (response.metadata || %{})
      |> Map.merge(%{
        terminal_tool: ctx.terminal_tool,
        terminal_args: ctx.terminal_args,
        terminal_tool_call: ctx.terminal_tool_call
      })

    %{response | metadata: metadata}
  end

  # -- Blank-stop recovery helpers ---------------------------------------------

  # Optional nudge message appended before a blank-stop retry. Breaks a
  # degenerate provider mode without changing the default retry contract
  # (unchanged messages).
  defp maybe_push_nudge(%{blank_stop_nudge: nil} = state), do: state

  defp maybe_push_nudge(%{blank_stop_nudge: nudge} = state) when is_binary(nudge) do
    %{state | messages: state.messages ++ [%{role: :user, content: nudge}]}
  end

  # Mark a response that succeeded only after blank-stop retries, so
  # downstream consumers can see recovery happened (bounded metadata).
  defp mark_blank_recovery(response, attempts) do
    metadata = Map.merge(response.metadata || %{}, %{blank_stop_retries: attempts})
    %{response | metadata: metadata}
  end

  defp finish_reason(%{metadata: %{finish_reason: finish_reason}}), do: finish_reason
  defp finish_reason(_response), do: nil

  # -- Helpers ----------------------------------------------------------------

  @spec maybe_notify((Context.t() -> :ok) | nil, Context.t()) :: :ok
  defp maybe_notify(nil, _ctx), do: :ok
  defp maybe_notify(callback, ctx), do: callback.(ctx)

  @spec emit_complete(non_neg_integer(), non_neg_integer()) :: :ok
  defp emit_complete(total_iterations, total_tool_calls) do
    :telemetry.execute(
      [:llm_core, :agent, :complete],
      %{total_iterations: total_iterations},
      %{tool_calls_count: total_tool_calls}
    )
  end
end
