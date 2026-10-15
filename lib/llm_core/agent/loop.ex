defmodule LlmCore.Agent.Loop do
  @moduledoc """
  Agentic tool-calling loop.

  Iterates: call LLM → feed response through the iteration pipeline →
  if the pipeline says `:continue`, append messages and call the LLM again;
  if `:done`, return the final response.

  A no-tool-call response with blank content (`:blank_stop`) is never
  accepted as completion. The loop retries the turn under a separately
  bounded recovery policy (`:max_blank_stops`) and terminates with a
  typed `{:empty_stop, details}` error when blanks repeat.

  With `:terminal_tool` and `:terminal_required`, a no-tool-call response
  with prose (`:nonterminal_stop`) is not accepted either: the model's prose
  is appended as an assistant message, a nudge follows as a user message,
  and the turn is retried. Narrated stops are budgeted per RUN
  (`:max_nonterminal_stops`), so a model that narrates, is nudged into one
  tool call and narrates again cannot reset the budget. Exhaustion — of that
  budget or of the iteration budget while the terminal tool was never called
  — terminates with the typed `{:terminal_missing, details}` error carrying
  the last prose, so the caller decides how to degrade.

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
          | {:terminal_required, boolean()}
          | {:terminal_nudge, String.t() | nil}
          | {:terminal_content_key, String.t() | nil}
          | {:max_nonterminal_stops, pos_integer()}
          | {:max_blank_stops, pos_integer()}
          | {:blank_stop_nudge, String.t() | nil}
        ]

  @default_max_iterations 10

  # Bounded recovery for degenerate empty-stop responses:
  # a provider returns HTTP success with finish_reason "stop", blank
  # content, and no tool calls while the task is still incomplete.
  # Per iteration, tolerate up to this many consecutive blank stops before
  # terminating with a typed {:empty_stop, details} error. Retries do not
  # consume the normal iteration budget — the two budgets are separate.
  @default_max_blank_stops 3

  # Bounded recovery for narrated stops under a required terminal tool: the
  # model answered in prose without calling the terminal tool. Counted
  # separately from blank stops and per RUN (not per iteration); retries do
  # not consume iterations.
  @default_max_nonterminal_stops 3

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
        `response.metadata.terminal_tool_call`. Sibling tool calls in the
        same response are dispatched before the loop returns, and their
        transcript is appended to the final messages.
      * `:terminal_required` — when `true` (requires `:terminal_tool`), a
        no-tool-call response with prose does not end the loop: the prose is
        appended as an assistant message, `:terminal_nudge` follows as a user
        message, and the turn is retried. Narrated stops are budgeted per run
        by `:max_nonterminal_stops`. Exhausting that budget, or the iteration
        budget before the terminal tool is called, returns
        `{:terminal_missing, %{iteration:, attempts:, last_content:,
        finish_reasons:, terminal_tool:, provider:, model:}}` (the iteration
        case adds `reason: :max_iterations`). A completion that needed retries
        is marked `response.metadata.terminal_recovery_attempts`.
      * `:terminal_nudge` — user-message text for the non-terminal retry.
        Defaults to a sentence naming the terminal tool.
      * `:terminal_content_key` — argument name of the terminal call whose
        string value becomes `response.content` (the model's own prose, if
        any, is kept under `response.metadata.terminal_prose`). A blank or
        missing argument leaves the content untouched.
      * `:max_nonterminal_stops` — max narrated stops tolerated per run
        under `:terminal_required` (default: #{@default_max_nonterminal_stops}).
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
    * `{:error, reason}` — Budget exceeded, LLM error, pipeline error,
      repeated blank stops (`{:empty_stop, %{iteration:, attempts:,
      finish_reasons:, provider:, model:}}`), or repeated narrated stops
      under a required terminal tool (`{:terminal_missing, details}`)

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
    terminal_required = Keyword.get(opts, :terminal_required, false) == true
    terminal_content_key = Keyword.get(opts, :terminal_content_key)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    max_blank_stops = Keyword.get(opts, :max_blank_stops, @default_max_blank_stops)
    blank_stop_nudge = Keyword.get(opts, :blank_stop_nudge)

    max_nonterminal_stops =
      Keyword.get(opts, :max_nonterminal_stops, @default_max_nonterminal_stops)

    if terminal_required and not is_binary(terminal_tool) do
      raise ArgumentError, ":terminal_required needs a :terminal_tool name"
    end

    terminal_nudge = Keyword.get(opts, :terminal_nudge) || default_terminal_nudge(terminal_tool)
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
      terminal_required: terminal_required,
      terminal_nudge: terminal_nudge,
      terminal_content_key: terminal_content_key,
      max_nonterminal_stops: max_nonterminal_stops,
      max_iterations: max_iterations,
      max_blank_stops: max_blank_stops,
      blank_stop_nudge: blank_stop_nudge,
      on_iteration: on_iteration,
      total_tool_calls: 0,
      last_error: nil,
      error_repeat_count: 0,
      # Narrated-stop budget is per RUN: a model that narrates, is nudged
      # into one tool call, then narrates again must not reset it.
      nonterminal_total: 0,
      last_narrated: nil,
      iteration: 0
    }

    result =
      0..(max_iterations - 1)
      |> Enum.reduce_while({:ok, initial_state}, fn iteration, {:ok, state} ->
        case do_iteration(state, llm_send_fn, llm_opts, iteration) do
          {:continue, new_state} ->
            {:cont, {:ok, new_state}}

          {:done, response, final_messages, total_tool_calls} ->
            {:halt, {:ok, response, final_messages, iteration + 1, total_tool_calls}}

          {:error, reason, state} ->
            {:halt, {:error, reason, state}}
        end
      end)

    case result do
      {:ok, response, final_messages, total_iterations, total_tool_calls} ->
        emit_complete(total_iterations, total_tool_calls)
        {:ok, response, final_messages}

      {:error, reason, state} ->
        {:error, terminalize_exhaustion(reason, state)}

      {:ok, state} ->
        emit_complete(max_iterations, state.total_tool_calls)
        {:error, terminalize_exhaustion(:max_iterations_reached, state)}
    end
  end

  # Under a required terminal tool, running out of iterations IS "the
  # terminal was never called": the caller gets the same typed error family
  # (with the last narrated prose, if any) instead of a bare budget error.
  defp terminalize_exhaustion(reason, %{terminal_required: true} = state)
       when reason in [:budget_exceeded, :max_iterations_reached] do
    {:terminal_missing,
     %{
       reason: :max_iterations,
       iteration: state.iteration,
       attempts: state.nonterminal_total,
       last_content: narrated_content(state.last_narrated),
       finish_reasons: [],
       terminal_tool: state.terminal_tool,
       provider: narrated_field(state.last_narrated, :provider),
       model: narrated_field(state.last_narrated, :model)
     }}
  end

  defp terminalize_exhaustion(reason, _state), do: reason

  defp narrated_content(nil), do: nil
  defp narrated_content(%{content: content}), do: content

  defp narrated_field(nil, _key), do: nil
  defp narrated_field(response, key), do: Map.get(response, key)

  # -- Private ----------------------------------------------------------------

  @spec do_iteration(map(), llm_send_fn(), keyword(), non_neg_integer()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:error, term(), map()}
  defp do_iteration(state, llm_send_fn, llm_opts, iteration) do
    recover_stops(%{state | iteration: iteration}, llm_send_fn, llm_opts, iteration, %{
      blank: 0,
      finish_reasons: []
    })
  end

  # Separately bounded stop recovery.
  #
  # A blank stop (no tool calls, blank content) and — under a required
  # terminal tool — a narrated stop (no tool calls, prose) each retry the
  # same iteration without consuming the iteration budget. Blank stops are
  # bounded per iteration (consecutive); narrated stops are bounded per RUN
  # (`state.nonterminal_total`). Exhaustion terminates with a typed
  # error (`{:empty_stop, details}` / `{:terminal_missing, details}`)
  # carrying bounded diagnostics: iteration number, attempt count, the
  # observed finish reasons and, for narrated stops, the last prose.
  @spec recover_stops(map(), llm_send_fn(), keyword(), non_neg_integer(), map()) ::
          {:continue, map()}
          | {:done, LlmCore.LLM.Response.t(), [map()], non_neg_integer()}
          | {:error, term(), map()}
  defp recover_stops(state, llm_send_fn, llm_opts, iteration, recovery) do
    case llm_send_fn.(state.messages, llm_opts) do
      {:ok, response} ->
        case process_response(state, response, iteration) do
          {:blank_stop, blank} ->
            attempts = recovery.blank + 1

            recovery = %{
              recovery
              | blank: attempts,
                finish_reasons: recovery.finish_reasons ++ [finish_reason(blank)]
            }

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
                  finish_reasons: recovery.finish_reasons,
                  provider: blank.provider,
                  model: blank.model
                }}, state}
            else
              require Logger

              Logger.warning(
                "[Agent.Loop] Blank stop (attempt #{attempts}/#{state.max_blank_stops}) at iteration #{iteration} — retrying"
              )

              state = maybe_push_nudge(state)
              recover_stops(state, llm_send_fn, llm_opts, iteration, recovery)
            end

          {:nonterminal_stop, narrated} ->
            attempts = state.nonterminal_total + 1
            state = %{state | nonterminal_total: attempts, last_narrated: narrated}

            recovery = %{
              recovery
              | finish_reasons: recovery.finish_reasons ++ [finish_reason(narrated)]
            }

            if attempts >= state.max_nonterminal_stops do
              require Logger

              Logger.warning(
                "[Agent.Loop] Terminal missing: #{attempts} narrated responses without #{state.terminal_tool} in this run (iteration #{iteration}) — terminating"
              )

              {:error,
               {:terminal_missing,
                %{
                  iteration: iteration,
                  attempts: attempts,
                  last_content: narrated.content,
                  finish_reasons: recovery.finish_reasons,
                  terminal_tool: state.terminal_tool,
                  provider: narrated.provider,
                  model: narrated.model
                }}, state}
            else
              require Logger

              Logger.warning(
                "[Agent.Loop] Narrated stop without #{state.terminal_tool} (attempt #{attempts}/#{state.max_nonterminal_stops}) at iteration #{iteration} — nudging"
              )

              state = push_terminal_nudge(state, narrated.content)
              recover_stops(state, llm_send_fn, llm_opts, iteration, recovery)
            end

          {:done, response, messages, tool_calls} ->
            {:done, mark_recovery(response, recovery, state), messages, tool_calls}

          {:continue, _state} = continue ->
            continue

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, {:llm_error, reason}, state}
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
      terminal_required: state.terminal_required,
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

    response =
      final_response
      |> attach_terminal_metadata(result_ctx)
      |> apply_terminal_content(result_ctx, state.terminal_content_key)

    {:done, response, state.messages ++ terminal_transcript(result_ctx),
     state.total_tool_calls + length(result_ctx.tool_calls)}
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

  defp handle_pipeline_result(
         %Context{decision: {:nonterminal_stop, response}} = result_ctx,
         state
       ) do
    maybe_notify(state.on_iteration, result_ctx)
    {:nonterminal_stop, response}
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

  # When the terminal response also carried sibling calls, those were
  # dispatched; their transcript (assistant message + tool results) joins
  # the final messages so the caller sees what actually ran. A lone
  # terminal call leaves the transcript untouched (0.5.0 contract).
  defp terminal_transcript(%Context{terminal_tool_call: %{}, tool_results: [_ | _]} = ctx),
    do: ctx.result_messages

  defp terminal_transcript(_ctx), do: []

  # `:terminal_content_key` — the terminal argument that IS the reply. The
  # model's own prose, when present, survives under metadata.terminal_prose.
  defp apply_terminal_content(response, %Context{terminal_tool_call: nil}, _key), do: response
  defp apply_terminal_content(response, _ctx, nil), do: response

  defp apply_terminal_content(response, %Context{terminal_args: args}, key) when is_map(args) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          response
        else
          metadata = response.metadata || %{}

          metadata =
            if is_binary(response.content) and String.trim(response.content) != "",
              do: Map.put(metadata, :terminal_prose, response.content),
              else: metadata

          %{response | content: value, metadata: metadata}
        end

      _ ->
        response
    end
  end

  defp apply_terminal_content(response, _ctx, _key), do: response

  defp default_terminal_nudge(nil), do: nil

  defp default_terminal_nudge(terminal_tool) when is_binary(terminal_tool) do
    "Your reply did not end the turn. Finish any remaining tool calls, then call #{terminal_tool} to report."
  end

  # -- Stop recovery helpers ---------------------------------------------------

  # A narrated stop keeps the model's prose in the transcript (so it does
  # not repeat itself) and follows it with the nudge, so the message list
  # still ends on a user turn.
  defp push_terminal_nudge(state, content) do
    %{
      state
      | messages:
          state.messages ++
            [%{role: :assistant, content: content}, %{role: :user, content: state.terminal_nudge}]
    }
  end

  # Mark a response that succeeded only after stop retries, so downstream
  # consumers can see recovery happened (bounded metadata).
  defp mark_recovery(response, %{blank: 0}, %{nonterminal_total: 0}), do: response

  defp mark_recovery(response, recovery, state) do
    metadata = response.metadata || %{}

    metadata =
      if recovery.blank > 0,
        do: Map.put(metadata, :blank_stop_retries, recovery.blank),
        else: metadata

    metadata =
      if state.nonterminal_total > 0,
        do: Map.put(metadata, :terminal_recovery_attempts, state.nonterminal_total),
        else: metadata

    %{response | metadata: metadata}
  end

  # Optional nudge message appended before a blank-stop retry. Breaks a
  # degenerate provider mode without changing the default retry contract
  # (unchanged messages).
  defp maybe_push_nudge(%{blank_stop_nudge: nil} = state), do: state

  defp maybe_push_nudge(%{blank_stop_nudge: nudge} = state) when is_binary(nudge) do
    %{state | messages: state.messages ++ [%{role: :user, content: nudge}]}
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
