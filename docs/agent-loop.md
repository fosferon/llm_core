# Agent Loop

LlmCore includes an in-process agentic tool-calling loop that runs entirely inside the BEAM VM — no subprocess, no CLI overhead.

## Overview

The agent loop implements the standard agentic pattern:

```
┌──────────────────────────────────────────┐
│           LlmCore.Agent.Loop             │
│                                          │
│  1. Call LLM with messages + tools       │
│  2. LLM responds with tool calls?        │
│     YES → dispatch tools, collect results │
│            append to messages → goto 1    │
│     NO  → return final text response     │
│                                          │
│  [Iteration Pipeline processes each turn] │
└──────────────────────────────────────────┘
```

The loop is transport-agnostic — it doesn't know about HTTP, CLIs, or specific providers. It calls a user-supplied `llm_send_fn` and a `resolve_tool` function. This makes it work with any LLM backend.

## Basic Usage

```elixir
alias LlmCore.Agent.Loop

# Define your LLM send function
llm_send = fn messages, opts ->
  LlmCore.LLM.Provider.dispatch(LlmCore.LLM.Anthropic, messages, opts)
end

# Define your tool resolver
resolve_tool = fn tool_call ->
  case tool_call.function_name do
    "search" -> {:ok, "search results..."}
    "calculate" -> {:ok, "42"}
    _ -> {:error, "unknown tool"}
  end
end

# Run the loop
{:ok, final_response, messages} =
  Loop.run(
    [%{role: :user, content: "What is 6 × 7?"}],
    llm_send,
    tools: [
      %LlmToolkit.Tool{
        name: "calculate",
        description: "Evaluate a mathematical expression",
        parameters: %{type: "object", properties: %{expr: %{type: "string"}}}
      }
    ],
    resolve_tool: resolve_tool,
    max_iterations: 10
  )

final_response.content
#=> "6 × 7 = 42"
```

## Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `:tools` | **Yes** | — | List of `LlmToolkit.Tool.t()` definitions |
| `:resolve_tool` | **Yes** | — | `fn(Call.t()) -> {:ok, String.t()} \| {:error, String.t()}` |
| `:resolver_module` | No | `nil` | Module implementing `ToolResolver` behaviour for dispatch recipes |
| `:terminal_tool` | No | `nil` | Tool name that stops the loop when called. The call is **not** dispatched — its raw arguments land on `response.metadata.terminal_args` and the full call on `response.metadata.terminal_tool_call`. Useful for letting the model select a structured result (e.g. citations) as its final turn. |
| `:max_iterations` | No | `10` | Hard iteration ceiling |
| `:on_iteration` | No | `nil` | Callback `fn(Context.t()) -> :ok` invoked after each iteration |
| `:pipeline_opts` | No | `[sync: true]` | Options forwarded to the ALF pipeline |
| `:llm_opts` | No | `[]` | Extra options forwarded to `llm_send_fn` |

## Return Values

| Result | Meaning |
|--------|---------|
| `{:ok, response, messages}` | LLM produced a text-only response. `response` is `LlmCore.LLM.Response.t()`, `messages` is the full conversation history. |
| `{:error, :max_iterations_reached}` | Iteration budget exhausted without a text-only response. |
| `{:error, {:circuit_breaker, msg}}` | Same tool error repeated 3+ times — systematic bug, not transient. |
| `{:error, {:llm_error, reason}}` | The `llm_send_fn` returned an error. |
| `{:error, {:pipeline_error, reason}}` | The ALF iteration pipeline crashed. |

## Iteration Pipeline

Each iteration flows through `LlmCore.Agent.Pipeline.Iteration`, an ALF pipeline with these stages:

```
parse_tool_calls       — Extract tool calls from the LLM response
     ↓
validate_calls         — Check calls against tool definitions
     ↓
loop_decision          — Text-only? → :done. Tool calls? → :continue
     ↓
dispatch_tools         — Execute tool calls (serial or parallel)
     ↓
inject_results         — Build tool result messages
     ↓
budget_guard           — Check iteration budget
```

The pipeline produces a `LlmCore.Agent.Context` with a `decision` field that the outer loop reads.

## Context Struct

`LlmCore.Agent.Context` carries data through the pipeline:

- **Input fields** (set by the loop): `messages`, `tools`, `response`, `resolve_tool`, `iteration`, `max_iterations`
- **Intermediate fields** (populated by stages): `tool_calls`, `tool_results`, `result_messages`, `validation_errors`
- **Output fields** (read by the loop): `decision`, `status`, `error`, `trace`

## Circuit Breaker

The loop detects when the same tool error repeats 3+ consecutive times. This indicates a systematic bug (wrong arguments, missing resource) rather than a transient failure — the model can't fix it by varying arguments. The loop breaks out with `{:error, {:circuit_breaker, msg}}`.

## Telemetry

The loop emits a single event on completion:

```elixir
:telemetry.execute(
  [:llm_core, :agent, :complete],
  %{total_iterations: N},
  %{tool_calls_count: N}
)
```

## Integration Example

A real-world consumer uses the agent loop for conversational LLM calls that need tool access:

```elixir
# From a consumer adapter
# (resolves provider, wraps LlmCore.LLM.Provider.dispatch/3 as the send function)
defp send_via_agent_loop(messages, opts, tools, resolve_tool) do
  {:ok, provider, call_opts} = resolve_provider(opts)

  llm_send_fn = fn loop_messages, loop_opts ->
    LlmCore.LLM.Provider.dispatch(provider, loop_messages, Keyword.merge(call_opts, loop_opts))
  end

  case LlmCore.Agent.Loop.run(messages, llm_send_fn,
         tools: tools,
         resolve_tool: resolve_tool,
         max_iterations: 5
       ) do
    {:ok, response, _final_messages} ->
      {:ok, response.content || "", response.usage || %{}}
    {:error, reason} ->
      {:error, reason}
  end
end
```

This pattern — resolve a provider, build a send function, pass it to the loop — is the recommended integration path for any application that needs tool-calling LLM interactions.
