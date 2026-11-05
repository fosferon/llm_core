# llm_core Architecture

This guide describes the internals of llm_core, a provider-agnostic LLM
orchestration library for Elixir. See the module documentation for the full
public API.

---

## Overview

```
┌──────────────────────────────────────────────────────────────┐
│                          llm_core                            │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │  Providers   │  │    Router    │  │      Memory        │  │
│  │  (adapters)  │  │  (ALF + ETS) │  │  (HTTP backends)   │  │
│  └──────────────┘  └──────────────┘  └────────────────────┘  │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │   Agent      │  │    Config    │  │    Telemetry       │  │
│  │   Loop       │  │  (TOML/ETS)  │  │  (spans/events)    │  │
│  └──────────────┘  └──────────────┘  └────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

The public facade (`LlmCore`) delegates to `LlmCore.Router` for inference and
`LlmCore.Memory` for semantic memory. Everything else is an internal
subsystem with module documentation.

---

## ALF pipelines

[ALF](https://github.com/antonmi/alf) is used as a composition DSL. A pipeline
is a list of stage functions over a context struct; stages short-circuit on
`status: :error`.

### Inference pipeline

`LlmCore.Pipelines.InferencePipeline`:

```
normalize_request
  ↓
extract_response_format
  ↓
resolve_route            ← Router / RoutingPipeline
  ↓
prepare_provider_opts
  ↓
ensure_streaming_capable
  ↓
ensure_structured_output_capable
  ↓
dispatch_provider        ← LlmCore.LLM.Provider.dispatch/3
  ↓
maybe_apply_structured_output
  ↓
finalize_result
```

Both blocking and streaming requests use the same pipeline; the mode selects
the dispatch path. `CommBus.Protocol.Packet` inputs are unpacked before
normalisation.

### Routing pipeline

`LlmCore.Pipelines.RoutingPipeline`:

```
normalize_task_type
  ↓
load_routing_table       ← Config.Store or merged config layers
  ↓
resolve_entry            ← task rule, else routing.default
  ↓
load_agent               ← Agent.Registry
  ↓
ensure_capabilities
  ↓
build_resolved_route
  ↓
finalize_result
```

With no rule and no default, the result is
`{:error, {:no_routing_default, %{task_type:, table_source:}}}`.
`RoutingPipeline.route/2` emits `[:llm_core, :routing, :error]`
unconditionally, including when span sampling is off.

### Memory pipeline

`LlmCore.Pipelines.MemoryPipeline`:

```
load_config
  ↓
normalize_request
  ↓
ensure_availability
  ↓
maybe_serve_from_cache
  ↓
circuit_gate
  ↓
execute_operation
  ↓
maybe_cache_result
  ↓
finalize_result
```

Retain operations can go through the write-behind buffer; recall/reflect use
the backend directly with cache and retry around them.

### Agent iteration pipeline

`LlmCore.Agent.Pipeline.Iteration`:

```
parse_tool_calls → validate_calls → budget_guard → dispatch_tools →
inject_results → loop_decision
```

The outer `LlmCore.Agent.Loop` owns iteration budgets, blank/narrated stop
recovery, the repeated-error circuit breaker and message accumulation.

### Tool dispatch pipeline

`LlmCore.Agent.Pipeline.ToolDispatch` handles tools whose resolver returns a
dispatch recipe:

```
resolve_strategy → switch
  ├─ passthrough → direct_resolve
  └─ recipe → build_plan → execute_serial → fan_out_parallel →
              execute_one_call(count: 3) → collect_results → compose_output
```

This is the only pipeline that runs asynchronously. It is a shared singleton:
callers start it in async mode and never stop or restart it. `DispatchTools`
passes a per-call ALF timeout derived from the caller's `:tool_timeout`
(default 300 s), so ALF's 10 s default does not cut long calls. Sub-calls run
in monitored processes, time out with `{:error, {:timeout, ms}}`, and parallel
results are reordered to the recipe's declared order.

---

## Provider system

### Behaviour contract

Module providers implement `LlmCore.LLM.Provider`:

```elixir
@callback send(prompt(), opts())       :: {:ok, Response.t()} | {:error, Error.t()}
@callback stream(prompt(), opts())     :: {:ok, Enumerable.t()} | {:error, Error.t()}
@callback available?()                 :: boolean()
@callback available?(auth :: map())    :: boolean()   # optional
@callback capabilities()               :: capabilities()
@callback provider_type()              :: :cli | :api | :local | :workflow
```

`LlmCore.LLM.Provider.dispatch/3` accepts a module, a `%CLIProvider{}` or any
struct with a `send/3` function. This is how config-driven CLI providers fit
without implementing the module callbacks.

### Built-in adapters

| Provider | Type | Module |
|----------|------|--------|
| Anthropic | `:api` | `LlmCore.LLM.Anthropic` |
| OpenAI-compatible | `:api` | `LlmCore.LLM.OpenAI` |
| Ollama | `:local` | `LlmCore.LLM.Ollama` |
| Appliance | `:local` | `LlmCore.LLM.Appliance` |
| CLI tools | `:cli` | `LlmCore.LLM.CLIProvider` |
| Native loop | `:api` | `LlmCore.LLM.Native` |

### Provider and CLI registries

- `LlmCore.Provider.Registry` — ETS metadata for all providers loaded from
  TOML; used for alias lookup and capability matching.
- `LlmCore.Agent.Registry` — alias → `Agent` mapping. TOML entries win; a
  fallback list covers the always-compiled provider modules.
- `LlmCore.CLIProvider.Registry` — list/available/fetch/resolve/capabilities
  over CLI configs.

### CLI providers

CLI providers are data, not modules. TOML controls the binary, subcommand,
flags, prompt transport, system-prompt transport, output capture, preflight
and automation profiles. `prompt_transport` supports `"last"` and
`"flagged"`; `"stdin"` is rejected by the loader because the CLI stdin pipe is
not written to.

Model selection is controlled by `model_resolution`:

- `"caller_default"` — documented neutral value; use `default_model` only
  when the caller passes no model.
- `"provider_runtime"` — let the CLI choose.
- `"explicit_only"` — only the caller's model.
- `"gc_default"` — deprecated alias for `"caller_default"`, accepted in
  0.9.x and removed in 0.10.

---

## Structured output

`LlmCore.Structured` provides JSON-mode extraction and validation without a
required Instructor dependency:

- **Function validator** — `(map -> {:ok, term} | {:error, term})`.
- **Module validator** — `validate/1`, `cast/1`, `from_map/1`, `new/1`, or an
  Ecto `changeset/2`.
- **Map schema** — `%{required: [...], optional: [...]}` checks that required
  keys are present and filters to allowed keys.
- **List schema** — list of required keys.

The built-in map/list schemas check **required keys only**. JSON Schema
`type`, `properties`, ranges and nested constraints are not enforced; use a
function or module validator when those matter.

`LlmCore.Structured.InstructorAdapter` is optional and compiles only when
Instructor is available.

---

## Routing system

The router resolves task types from TOML:

- `routing.default` — fallback entry; no default ships with the library.
- `routing.tasks.<task>` — task-specific alias, mode and capabilities.
- A project `routing.yml` takes precedence over TOML routing.

The Router refreshes on `{:config_reloaded, :routing}` and polls every 60 s.
`RoutingPipeline` reads the current table from `Config.Store` (or an explicit
table passed by the caller).

---

## Memory integration

`LlmCore.Memory` is the facade and `LlmCore.Memory.Backend` the contract:
`available?/0`, `retain/3`, `retain_sync/3`, `recall/2`, `reflect/2`.

Backends:

- `hindsight_rest` (default) — Hindsight REST API, not MCP.
- `foresight_http` — Hindsight-compatible HTTP endpoint.
- `foresight_inprocess` — optional; the host starts `Foresight.Supervisor`.

The HTTP backends share cache, circuit breaker, retry with backoff, and a
write-behind buffer. The buffer traps exits so a graceful supervisor shutdown
calls `terminate/2` and persists queued retains; a hard kill cannot be
intercepted.

### Configuration precedence

1. UI/runtime override (ETS, session-only)
2. Project config
3. Global config
4. `HINDSIGHT_URL`
5. Auto-discovered endpoint

---

## Configuration system

### Layered sources

```
1. Bundled priv/config/llm_core.toml
2. ~/.llm_core/config/llm_core.toml
3. <project>/.llm_core/llm_core.toml
4. $LLM_CORE_CONFIG
5. opts[:path]
6. Runtime ETS overrides
```

Later sources override earlier ones. `${VAR:default}` placeholders are
interpolated at load time.

### Hot reload

`LlmCore.Config.Watcher` watches the **project** config directory
(`<project>/.llm_core/`) with a 100 ms debounce and reloads the affected
section. The global layer, the bundled layer and `LLM_CORE_CONFIG` are not
watched: they are read at boot or by an explicit reload.

The normalised snapshot lives in `LlmCore.Config.Store` (ETS), so the router,
provider registry and memory pipeline see the new values after a reload.

`DEVMAN_HOME` and `DEVMAN_CONFIG` remain accepted for compatibility as
fallbacks for `LLM_CORE_HOME` and `LLM_CORE_PROJECT_CONFIG`; each emits one
deprecation warning per VM and will be removed in 0.10.

### Execution control

`LlmCore.Executor.Control` is an ETS registry of active CLI ports keyed by
`execution_id`. `CLIProvider.send/3` and `stream/3` register the port when the
caller passes `execution_id:`. A consumer can call `Control.lookup/1` and close
the port to interrupt the CLI process. This is best-effort and requires the
caller to supply an id.

---

## Telemetry events

```elixir
# Pipeline spans — each has :start, :stop, :exception
[:llm_core, :inference_pipeline, ...]
[:llm_core, :routing_pipeline, ...]
[:llm_core, :memory_pipeline, ...]
[:llm_core, :provider_dispatch, ...]

# Routing failures (unconditional)
[:llm_core, :routing, :error]

# Config
[:llm_core, :config, :reloaded]

# Agent loop
[:llm_core, :agent, :loop_iteration]
[:llm_core, :agent, :tool_call, :start]
[:llm_core, :agent, :tool_call, :stop]
[:llm_core, :agent, :complete]

# Tool dispatch
[:llm_core, :tool_dispatch, :sub_call, :start]

# Memory health
[:llm_core, :hindsight, :health]
```

Span sampling and the built-in logger are controlled by
The telemetry settings control sampling and the logger; the routing error event is not sampled.

---

## Testing approach

- Unit tests for provider adapters, config loading/merging, routing rules,
  structured validation and agent stages.
- Integration tests for provider → router → response, memory flows, config
  reload and the async tool-dispatch pipeline.
- Property-based tests with StreamData for routing precedence and config
  merge behaviour.
- Mox is available for provider mocking.
