# LlmCore Architecture

Provider-agnostic LLM orchestration for Elixir. A request is normalised,
routed to a provider, and returned as a `LlmCore.LLM.Response` (or a typed
error). Optional layers add structured output, semantic memory, and an
in-process tool-calling agent loop.

## Request flow

```
                         ┌──────────────────────────────────────┐
                         │          LlmCore (facade)            │
                         │ send/3 · stream/3 · retain/2 · ...   │
                         └──────────────────┬───────────────────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              ▼                             ▼                             ▼
    ┌──────────────────┐          ┌──────────────────┐        ┌──────────────────┐
    │ InferencePipeline│─────────▶│ RoutingPipeline  │        │ MemoryPipeline   │
    │      (ALF)       │          │      (ALF)       │        │      (ALF)       │
    └────────┬─────────┘          └────────┬─────────┘        └────────┬─────────┘
             │                             │                           │
             │                    ┌────────▼─────────┐        ┌────────▼─────────┐
             │                    │      Router      │        │ Memory facade +  │
             │                    │    (GenServer)   │        │ backend (HTTP)   │
             │                    └────────┬─────────┘        └──────────────────┘
             │                             │
             │                    ┌────────▼─────────┐
             │                    │ Agent.Registry   │
             │                    │ Provider.Registry│
             │                    │ (ETS from TOML)  │
             │                    └────────┬─────────┘
             ▼                             ▼
    ┌─────────────────────────────────────────────────────┐
    │                  Provider dispatch                   │
    │  Anthropic · OpenAI-compatible · Ollama · Appliance  │
    │  CLIProvider (config-driven CLI tools)               │
    └─────────────────────────────────────────────────────┘
```

## Core subsystems

### 1. Router (`LlmCore.Router`)

A GenServer that resolves task types (`"coding"`, `"reasoning"`, ...) to a
`LlmCore.Router.ResolvedRoute`.

- Loads routing rules from the merged TOML layers (`[routing]`) and from a
  project `routing.yml`, which takes precedence for routing.
- Keeps a routing table in GenServer state and refreshes it on
  `{:config_reloaded, :routing}` plus a 60 s safety-net poll.
- Delegates execution to `InferencePipeline` for `send/3` and `stream/3`.

Structs:

| Struct | Purpose |
|--------|---------|
| `RouteEntry` | One routing rule: alias, mode, capability requirements |
| `RoutingTable` | Rules + optional default |
| `ResolvedRoute` | Final decision with hydrated `Agent` |

With no default in any layer, resolution returns
`{:error, {:no_routing_default, %{task_type:, table_source:}}}` and emits
`[:llm_core, :routing, :error]` unconditionally.

### 2. Provider system

#### Behaviour (`LlmCore.LLM.Provider`)

Module providers implement:

```elixir
@callback send(prompt(), opts())       :: {:ok, Response.t()} | {:error, Error.t()}
@callback stream(prompt(), opts())     :: {:ok, Enumerable.t()} | {:error, Error.t()}
@callback available?()                 :: boolean()
@callback available?(auth :: map())    :: boolean()   # optional
@callback capabilities()               :: capabilities()
@callback provider_type()              :: :cli | :api | :local | :workflow
```

`Provider.dispatch/3` handles both modules and structs. `CLIProvider` is a
struct-based provider: its config is data, and it is called through
`dispatch/3` rather than implementing the module callbacks.

Built-in adapters:

- `LlmCore.LLM.Anthropic` — Anthropic Messages API.
- `LlmCore.LLM.OpenAI` — OpenAI-compatible chat completions; also used for
  other compatible endpoints with a different `base_url` and key.
- `LlmCore.LLM.Ollama` — local Ollama server.
- `LlmCore.LLM.Appliance` — any OpenAI-compatible local appliance.
- `LlmCore.LLM.CLIProvider` — one universal, TOML-configured CLI adapter.
- `LlmCore.LLM.Native` — in-process loop over a configured provider cascade.

#### Registries

- `LlmCore.Provider.Registry` — ETS view of provider definitions loaded from
  TOML (aliases, capabilities, availability).
- `LlmCore.Agent.Registry` — GenServer mapping aliases to `Agent` structs.
  TOML-registered agents win; a small fallback list covers provider modules
  that are always compiled in.
- `LlmCore.CLIProvider.Registry` — query surface over CLI configs (list,
  available, fetch, resolve, capabilities).

#### CLI providers

CLI tools are declared entirely in TOML (`type = "cli"`). The adapter builds
the command line from fields such as `binary`, `subcommand`, flags,
`prompt_transport`, `system_prompt_transport`, output mode and preflight
checks. Prompt transports are `"last"` and `"flagged"`. The legacy `"stdin"`
value is accepted through 0.9.x as a deprecated alias for `"last"` and logs a
one-time warning; it is removed in 0.10.

Model selection follows `model_resolution`:

- `"gc_default"` — the implicit value in 0.9.x when `default_model` is set.
  It uses `default_model` only when the caller passes no model.
- `"caller_default"` — the preferred spelling of `"gc_default"`. It behaves
  identically and, when configured explicitly, reads back as
  `"caller_default"`. The implicit value flips to `"caller_default"` in 0.10.
- `"provider_runtime"` — let the CLI choose its own default.
- `"explicit_only"` — only the caller's model.

### 3. ALF pipelines

llm_core uses [ALF](https://hexdocs.pm/alf) as a composition DSL. The request
pipelines run through `ALF.Manager` in synchronous mode; `ToolDispatch` runs
asynchronously so recipe sub-calls can overlap.

#### Inference (`LlmCore.Pipelines.InferencePipeline`)

```
normalize_request → extract_response_format → resolve_route →
prepare_provider_opts → ensure_streaming_capable →
ensure_structured_output_capable → dispatch_provider →
maybe_apply_structured_output → finalize_result
```

Accepts strings, message lists, or `CommBus.Protocol.Packet` structs, and
handles both `:send` and `:stream`.

#### Routing (`LlmCore.Pipelines.RoutingPipeline`)

```
normalize_task_type → load_routing_table → resolve_entry → load_agent →
ensure_capabilities → build_resolved_route → finalize_result
```

#### Memory (`LlmCore.Pipelines.MemoryPipeline`)

```
load_config → normalize_request → ensure_availability →
maybe_serve_from_cache → circuit_gate → execute_operation →
maybe_cache_result → finalize_result
```

#### Agent iteration (`LlmCore.Agent.Pipeline.Iteration`)

```
parse_tool_calls → validate_calls → budget_guard → dispatch_tools →
inject_results → loop_decision
```

One iteration per LLM response. `LlmCore.Agent.Loop` owns the outer
`Enum.reduce_while`, budgets, stop recovery and message accumulation.

#### Tool dispatch (`LlmCore.Agent.Pipeline.ToolDispatch`)

Used when a resolver implements `dispatch_recipe/1` and returns a recipe for
a tool:

```
resolve_strategy → switch
  ├─ passthrough → direct_resolve
  └─ recipe → build_plan → execute_serial → fan_out_parallel →
              execute_one_call(count: 3) → collect_results → compose_output
```

The pipeline is started in async mode and shared by all callers. A dispatch
carries a deadline only when the caller supplies `:tool_timeout`. With no
caller budget the default is `:infinity`: there is no deadline and ALF is
called with `timeout: :infinity`, so its 10 s default is not used. Finite
budgets are enforced around every sub-call; timeouts report the configured
budget and parallel results are reordered to the recipe's declared order
before composition.

### 4. Agent loop

`LlmCore.Agent.Loop.run/3` is an in-process loop over a user-supplied
`llm_send_fn` and `resolve_tool`.

- Iteration budget: `:max_iterations` (default 10).
- Blank stops: `:max_blank_stops` (default 3, per iteration).
- Narrated stops under `:terminal_required`: `:max_nonterminal_stops`
  (default 3, per run).
- Repeated tool errors: circuit breaker after 3 identical fingerprints.
- Optional terminal tool and terminal-content extraction.
- Tool dispatch timeout: `:tool_timeout` (default `:infinity` — no deadline;
  a positive millisecond value enables a deadline).

### 5. Structured output

`LlmCore.Structured` extracts JSON and validates it with one of:

| Schema | Validation |
|--------|------------|
| Function | Direct invocation |
| Module | `validate/1`, `cast/1`, `from_map/1`, `new/1`, or Ecto `changeset/2` |
| `%{required: [...], optional: [...]}` | Required-key presence; optional keys filter the result |
| `[key, ...]` | Required-key presence |

The built-in map/list schemas check **required keys only** — JSON Schema
`type`, `properties`, ranges and nested constraints are not enforced. Use a
function or module validator for full schema semantics. The optional
`LlmCore.Structured.InstructorAdapter` compiles only when Instructor is
available.

### 6. Memory

`LlmCore.Memory` is the facade; `LlmCore.Memory.Backend` is the contract.
Backends: `hindsight_rest` (default), `foresight_http`, and
`foresight_inprocess`. Hindsight uses its REST API, not MCP.

The HTTP backends share:

| Component | Purpose |
|-----------|---------|
| `Hindsight.Cache` | TTL + LRU, stale-while-revalidate, single-flight refresh |
| `Hindsight.CircuitBreaker` | Closed → open after failures; half-open probe |
| `Hindsight.Retry` | Exponential backoff with jitter |
| `Hindsight.WriteBuffer` | Batches retains; persists the buffer on graceful shutdown |
| `Hindsight.Monitor` | Health checks and startup discovery |
| `Hindsight.Discovery` | Probes localhost/127.0.0.1:8888 when no URL is configured |

`WriteBuffer` traps exits so a supervisor shutdown calls `terminate/2` and
the buffered retains are persisted. A hard kill still cannot be intercepted.

### 7. Configuration

Layered TOML, later layers overriding earlier ones:

```
<app_priv>/config/llm_core.toml          bundled defaults
~/.llm_core/config/llm_core.toml         global user config
<project>/.llm_core/llm_core.toml        project config
$LLM_CORE_CONFIG                          env override
opts[:path]                               explicit path
```

`${VAR:default}` placeholders are interpolated at load time. A project
`routing.yml` overrides TOML routing.

| Component | Responsibility |
|-----------|----------------|
| `Config.Loader` | Read TOML/YAML, normalise providers, apply sections |
| `Config.Store` | Public ETS store for routing, providers, memory, telemetry |
| `Config.Watcher` | Debounced watch of the **project** config directory only |
| `Config.Editor` / `Config.TomlWriter` | Safe mutation and deterministic encoding |

Hot reload is scoped to `<project>/.llm_core/`. The global, bundled and
explicit-path layers are read at boot or by an explicit reload. `DEVMAN_HOME`
and `DEVMAN_CONFIG` remain accepted as deprecated fallbacks for
`LLM_CORE_HOME` and `LLM_CORE_PROJECT_CONFIG`; each emits one warning per VM
and will be removed in 0.10.

### 8. Execution control (`LlmCore.Executor.Control`)

An ETS registry of active CLI ports keyed by execution id. `CLIProvider`
registers a port when the caller passes `execution_id:`. A consumer can call
`Control.lookup/1` and close that port to interrupt an in-flight CLI call.
This is best-effort: closing the port signals EOF to the child process.

### 9. Telemetry

Emitted events:

```elixir
[:llm_core, :inference_pipeline, :start | :stop | :exception]
[:llm_core, :routing_pipeline, :start | :stop | :exception]
[:llm_core, :memory_pipeline, :start | :stop | :exception]
[:llm_core, :provider_dispatch, :start | :stop | :exception]
[:llm_core, :routing, :error]            # unconditional
[:llm_core, :config, :reloaded]
[:llm_core, :agent, :loop_iteration]
[:llm_core, :agent, :tool_call, :start | :stop]
[:llm_core, :agent, :complete]
[:llm_core, :tool_dispatch, :sub_call, :start]
[:llm_core, :hindsight, :health]
```

`Telemetry.Settings` controls span sampling and the optional logger.
`Telemetry.Logger` attaches to the three request-pipeline and provider
dispatch stop/exception events.

### 10. Mix tasks

| Task | Purpose |
|------|---------|
| `mix llm_core.config.show` | Display merged configuration |
| `mix llm_core.config.set` | Mutate TOML and reload |
| `mix llm_core.config.validate` | Validate TOML and availability |
| `mix llm_core.bench` | Routing/inference benchmarks |

## Module index

```
lib/
├── llm_core.ex                          # Public facade
├── llm_core/
│   ├── application.ex                   # Supervision tree
│   ├── agent.ex                         # Agent struct + name validation
│   ├── paths.ex                         # Path helpers (env overrides)
│   ├── telemetry.ex                     # Span helper
│   ├── structured.ex                    # Structured output dispatcher
│   ├── agent/
│   │   ├── context.ex                   # Iteration context
│   │   ├── loop.ex                      # Outer agent loop
│   │   ├── registry.ex                  # Agent GenServer
│   │   ├── components/                  # Parse, validate, dispatch, inject,
│   │   │                                # decision, budget guard
│   │   ├── pipeline/
│   │   │   ├── iteration.ex             # Per-iteration ALF pipeline
│   │   │   └── tool_dispatch.ex         # Recipe dispatch ALF pipeline
│   │   └── tool_dispatch/
│   │       ├── event.ex                 # Dispatch event
│   │       ├── execution.ex             # Bounded sub-call runner
│   │       └── components/              # Recipe stages and composers
│   ├── cli_provider/
│   │   └── registry.ex                  # CLI config query surface
│   ├── config/
│   │   ├── loader.ex                    # TOML/YAML loader + normaliser
│   │   ├── store.ex                     # ETS runtime store
│   │   ├── watcher.ex                   # Project-layer file watcher
│   │   ├── editor.ex                    # Config mutation helpers
│   │   └── toml_writer.ex               # TOML encoder
│   ├── execution/
│   │   └── control.ex                   # Active CLI port registry
│   ├── llm/
│   │   ├── provider.ex                  # Behaviour + unified dispatch
│   │   ├── response.ex / error.ex       # Unified result structs
│   │   ├── messages.ex                  # Prompt normalisation
│   │   ├── sse_parser.ex                # Server-Sent Events parser
│   │   ├── cli_port.ex                  # Port helpers used by consumers
│   │   ├── cli_provider.ex              # Universal TOML CLI adapter
│   │   ├── anthropic.ex                 # Anthropic API
│   │   ├── openai.ex                    # OpenAI-compatible API
│   │   ├── ollama.ex                    # Ollama
│   │   ├── appliance.ex                 # Local OpenAI-compatible appliance
│   │   ├── native.ex                    # In-process cascade loop
│   │   └── native/{config,router}.ex    # Native config + candidate routing
│   ├── memory/
│   │   ├── memory facade + backend contract
│   │   ├── backend/                     # hindsight_rest, foresight_http,
│   │   │                                # foresight_in_process
│   │   ├── config.ex                    # Backend selection
│   │   └── hindsight/                   # cache, circuit breaker, retry,
│   │                                    # write buffer, monitor, discovery
│   ├── pipelines/
│   │   ├── inference_pipeline.ex
│   │   ├── routing_pipeline.ex
│   │   └── memory_pipeline.ex
│   ├── provider/
│   │   ├── definition.ex                # Provider metadata
│   │   └── registry.ex                  # ETS provider lookup
│   ├── router/
│   │   ├── router.ex                    # Router GenServer
│   │   └── structs.ex                   # Route structs
│   ├── structured/
│   │   ├── instructor_adapter.ex
│   │   ├── json_mode.ex
│   │   └── validator.ex
│   ├── telemetry/
│   │   ├── settings.ex
│   │   └── logger.ex
│   └── tool/
│       ├── codec.ex                     # Tool-call codecs
│       └── validator.ex                 # Tool-call validation
└── mix/tasks/
    ├── llm_core.bench.ex
    ├── llm_core.config.set.ex
    ├── llm_core.config.show.ex
    └── llm_core.config.validate.ex
```

## Supervision tree

```
LlmCore.Supervisor (one_for_one)
├── LlmCore.Config.Store                 (ETS owner)
├── LlmCore.Agent.Registry               (GenServer)
├── LlmCore.Router                       (GenServer)
├── LlmCore.Config.Watcher               (GenServer, optional)
└── LlmCore.Memory.Hindsight.Supervisor  (optional, when memory is enabled)
    ├── Cache                            (GenServer + ETS)
    ├── WriteBuffer                      (GenServer; traps exits)
    ├── CircuitBreaker                   (GenServer)
    ├── Task.Supervisor                  (memory background work)
    └── Monitor                          (health checks)
```

Boot is transactional: if provider/routing loading or the memory subtree
fails to start, the supervisor is stopped and `{:error, reason}` is returned.

## Design decisions

1. **ALF as a composition DSL** — stage lists are declarative and testable.
   The request pipelines use synchronous ALF calls; `ToolDispatch` uses the
   async pipeline with the caller's explicit per-call timeout, or with
   `timeout: :infinity` when the caller set no budget.

2. **Behaviour plus struct dispatch** — module providers use a behaviour for
   compile-time contracts; config-driven CLI providers are structs routed by
   `Provider.dispatch/3`, so adding a CLI is a TOML edit.

3. **ETS for hot config** — routing and provider metadata are read without a
   GenServer round-trip. The watcher reloads the project layer into ETS.

4. **Explicit failure over guessed defaults** — no routing default is
   shipped. Missing configuration returns a typed error and emits an
   unconditional routing event.

5. **Resilience without hiding failures** — cache, circuit breaker and retry
   sit around memory I/O; persistent failures surface as typed errors.

6. **Caller-owned tool dispatch budget** — recipe sub-calls run concurrently
   and have no deadline unless the caller supplies one. Finite budgets return
   typed timeout errors instead of hanging the loop or restarting a shared
   pipeline.
