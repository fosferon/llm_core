# LlmCore Architecture

Provider-agnostic LLM orchestration library for Elixir. Every model call
routes through llm_core — provider selection, structured output extraction,
Hindsight semantic memory, circuit breakers, retries, and caching.

## Request Flow

```
                          ┌──────────────────────────────────────────────┐
                          │              LlmCore (Facade)               │
                          │   send/3 · stream/3 · retain/2 · recall/2   │
                          └────────────────┬─────────────────────────────┘
                                           │
                    ┌──────────────────────┤──────────────────────┐
                    ▼                      ▼                      ▼
           ┌───────────────┐     ┌─────────────────┐    ┌────────────────┐
           │ InferencePipe │     │  RoutingPipeline │    │ MemoryPipeline │
           │   (ALF)       │────▶│     (ALF)        │    │    (ALF)       │
           └───────┬───────┘     └────────┬────────┘    └───────┬────────┘
                   │                      │                     │
                   │              ┌───────▼────────┐    ┌───────▼────────┐
                   │              │  Router (GenSrv)│    │   Hindsight    │
                   │              │  routing.yml +  │    │  REST client   │
                   │              │  RoutingTable    │    │  write buffer  │
                   │              └───────┬────────┘    │  circuit break  │
                   │                      │             │  cache + retry  │
                   │              ┌───────▼────────┐    └────────────────┘
                   │              │ Agent.Registry  │
                   │              │  (GenServer)    │
                   │              └───────┬────────┘
                   │                      │
                   │           ┌──────────▼──────────┐
                   │           │  Provider.Registry   │
                   │           │  (ETS, from TOML)    │
                   │           └──────────┬──────────┘
                   │                      │
                   ▼                      ▼
           ┌──────────────────────────────────────────┐
           │            LLM Provider Adapters          │
           │                                           │
           │  ┌──────────┐ ┌────────┐ ┌────────────┐  │
           │  │ Anthropic │ │ OpenAI │ │   Ollama   │  │
           │  │  (API)    │ │ (API)  │ │  (local)   │  │
           │  └──────────┘ └────────┘ └────────────┘  │
           │  ┌──────────┐ ┌────────┐ ┌────────────┐  │
           │  │ClaudeCode│ │ Gemini │ │ Appliance  │  │
           │  │  (CLI)   │ │ (CLI)  │ │  (local)   │  │
           │  └──────────┘ └────────┘ └────────────┘  │
           │  ┌──────────┐ ┌────────┐                  │
           │  │   Z.ai   │ │ Codex  │                  │
           │  │  (API)   │ │ (CLI)  │                  │
           │  └──────────┘ └────────┘                  │
           └──────────────────────────────────────────┘
```

## Core Subsystems

### 1. Router (`LlmCore.Router`)

A GenServer that resolves **task types** (e.g. `"coding"`, `"reasoning"`,
`"planning"`) to fully-configured agent/provider pairs.

- Loads routing rules from `routing.yml` via `LlmCore.Config.Loader`
- Stores the active `RoutingTable` in-process and syncs every 60 s
- Responds to `:config_reloaded` messages from the file watcher
- Delegates execution to `InferencePipeline` for `send/3` and `stream/3`

**Key structs:**

| Struct | Purpose |
|--------|---------|
| `RouteEntry` | One routing rule: alias → provider, mode, capabilities |
| `RoutingTable` | All rules + default, built from YAML or TOML |
| `ResolvedRoute` | Final routing decision with hydrated `Agent` |

### 2. Provider System

#### Provider Behaviour (`LlmCore.LLM.Provider`)

Every adapter implements five callbacks:

```elixir
@callback send(prompt(), opts())       :: {:ok, Response.t()} | {:error, Error.t()}
@callback stream(prompt(), opts())     :: {:ok, Enumerable.t()} | {:error, Error.t()}
@callback available?()                 :: boolean()
@callback capabilities()               :: capabilities()
@callback provider_type()              :: :cli | :api | :local
```

Three provider types exist:

- **API** — Anthropic, OpenAI, Z.ai, Appliance (HTTP JSON)
- **CLI** — Claude Code, Gemini CLI, Codex CLI (via `CLIPort`)
- **Local** — Ollama, Appliance (OpenAI-compatible over localhost)

#### Provider Registry (`LlmCore.Provider.Registry`)

Read-only ETS view over provider definitions loaded from TOML. Used by the
routing pipeline for capability matching and alias suggestions.

#### Agent Registry (`LlmCore.Agent.Registry`)

GenServer that maps human-friendly names (aliases) to `Agent` structs. On
startup it auto-discovers providers from definitions or falls back to
hard-coded entries. Explicitly registered agents take priority over
auto-discovered ones.

### 3. ALF Pipelines

llm_core uses [ALF](https://hexdocs.pm/alf) (Application Layer Framework) to
compose processing stages into declarative, synchronous pipelines.

#### Inference Pipeline (`LlmCore.Pipelines.InferencePipeline`)

```
normalize_request → extract_response_format → resolve_route →
prepare_provider_opts → ensure_streaming_capable →
ensure_structured_output_capable → dispatch_provider →
maybe_apply_structured_output → finalize_result
```

Accepts strings, message lists, or `CommBus.Protocol.Packet` structs.
Handles both `:send` and `:stream` modes.

#### Routing Pipeline (`LlmCore.Pipelines.RoutingPipeline`)

```
normalize_task_type → load_routing_table → resolve_entry →
load_agent → ensure_capabilities → build_resolved_route →
finalize_result
```

Resolves a task type string to a `ResolvedRoute` with full agent metadata.
Used internally by the inference pipeline and available for standalone routing.

#### Memory Pipeline (`LlmCore.Pipelines.MemoryPipeline`)

```
load_config → normalize_request → ensure_availability →
maybe_serve_from_cache → circuit_gate → execute_operation →
maybe_cache_result → finalize_result
```

Orchestrates all Hindsight operations (retain, recall, reflect) with
caching, circuit breaker gating, retries, and write buffering.

### 4. Structured Output

Lightweight JSON-mode extraction without heavy dependencies. The system
supports three schema types:

- **JSON Schema** — Provider-side `response_format` + post-response decode
  and validation
- **Custom** — User-supplied `(Response.t() -> {:ok, term()})` function
- **Instructor** — Optional Instructor adapter (`LlmCore.Structured.InstructorAdapter`)
  that delegates completions to the router

**Validation pipeline** (`LlmCore.Structured.Validator`):

| Schema type | How it validates |
|-------------|-----------------|
| Function `(map -> result)` | Direct invocation |
| Module with `validate/1` | Module callback |
| Module with `changeset/2` | Ecto changeset apply |
| Map `%{required: [...]}` | Key presence check |
| List `[:key1, :key2]` | Required keys |

### 5. Hindsight Memory Integration

Hindsight is an external semantic memory server (REST API, v0.4+). llm_core
wraps it with a resilience stack:

| Component | Purpose |
|-----------|---------|
| `Hindsight` | REST client (retain/recall/reflect/bank management) |
| `WriteBuffer` | Batch-sends retains every 5 s or at 50 items; persists to disk on shutdown |
| `CircuitBreaker` | Closed → Open after N failures; Half-open probe after reset timer |
| `Cache` | TTL + LRU; stale-while-revalidate with background refresh |
| `Retry` | Exponential backoff with jitter; classifies transient vs permanent errors |
| `Discovery` | Probes localhost:8888 / 127.0.0.1:8888 for auto-discovery |
| `Config` | Multi-level precedence: UI override > project > global > env > discovered |

All operations flow through the Memory Pipeline which gates on circuit
state and cache hits before touching the network.

### 6. Configuration System

llm_core uses a layered TOML configuration with hot-reload:

```
<app_priv>/config/llm_core.toml          (bundled defaults)
~/.llm_core/config/llm_core.toml         (global user config)
<project>/.llm_core/llm_core.toml        (project config)
$LLM_CORE_CONFIG                          (env override)
opts[:path]                               (explicit path)
```

Later layers deep-merge over earlier ones. Environment variable placeholders
(`${VAR_NAME:default}`) are interpolated at load time.

| Component | Responsibility |
|-----------|---------------|
| `Config.Loader` | Reads TOML/YAML, normalizes providers, applies config sections |
| `Config.Store` | ETS-backed runtime store for routing tables and provider metadata |
| `Config.Watcher` | `FileSystem`-based watcher with debounced reload |
| `Config.Editor` | Read/write/update helpers for `llm_core.toml` mutation |
| `Config.TomlWriter` | Deterministic TOML encoder for the editor |

**Routing config** is separate (`routing.yml`) and supports both flat alias
strings and rich maps with mode and capability requirements.

### 7. Execution Control (`LlmCore.Executor.Control`)

Minimal ETS registry that tracks active CLI ports by execution ID. This
enables HALT semantics — consumers can interrupt in-flight CLI operations
by looking up and closing the port.

### 8. Telemetry

All pipelines emit `:telemetry` events:

- `[:llm_core, <pipeline>, :start]`
- `[:llm_core, <pipeline>, :stop]` with duration
- `[:llm_core, <pipeline>, :exception]` with error details

`Telemetry.Settings` controls sampling rate and per-event enablement via
TOML config. `Telemetry.Logger` is an optional handler that logs events.

### 9. Mix Tasks

| Task | Purpose |
|------|---------|
| `mix llm_core.config.show` | Display merged config (providers, routing, memory, telemetry) |
| `mix llm_core.config.set` | Mutate `llm_core.toml` entries and reload |
| `mix llm_core.config.validate` | Validate TOML and print provider availability |
| `mix llm_core.bench` | Run ALF routing/inference benchmarks |

## Module Index

```
lib/
├── llm_core.ex                          # Public facade
├── llm_core/
│   ├── application.ex                   # OTP application / supervision tree
│   ├── agent.ex                         # Agent struct + name validation
│   ├── paths.ex                         # Path resolution helpers
│   ├── telemetry.ex                     # Telemetry span helper
│   ├── structured.ex                    # Structured output dispatcher
│   ├── agent/
│   │   └── registry.ex                  # Agent GenServer registry
│   ├── config/
│   │   ├── loader.ex                    # TOML/YAML loader + normalizer
│   │   ├── store.ex                     # ETS runtime config store
│   │   ├── watcher.ex                   # File-change watcher
│   │   ├── editor.ex                    # Config file mutation helpers
│   │   └── toml_writer.ex              # TOML encoder
│   ├── execution/
│   │   └── control.ex                   # CLI port tracking for HALT
│   ├── llm/
│   │   ├── provider.ex                  # Provider behaviour definition
│   │   ├── response.ex                  # Unified response struct
│   │   ├── error.ex                     # Unified error struct
│   │   ├── messages.ex                  # Prompt normalization helpers
│   │   ├── sse_parser.ex               # Server-Sent Events parser
│   │   ├── cli_port.ex                 # Port-based CLI execution
│   │   ├── anthropic.ex                # Anthropic Claude API adapter
│   │   ├── openai.ex                   # OpenAI-compatible API adapter
│   │   ├── ollama.ex                   # Ollama local adapter
│   │   ├── appliance.ex               # Generic local appliance adapter
│   │   ├── claude_code.ex             # Claude Code CLI adapter
│   │   ├── gemini_cli.ex             # Gemini CLI adapter
│   │   ├── codex_cli.ex              # Codex CLI adapter
│   │   └── zai.ex                     # Z.ai API adapter
│   ├── memory/
│   │   ├── hindsight.ex               # Hindsight REST client
│   │   └── hindsight/
│   │       ├── supervisor.ex          # Hindsight supervision tree
│   │       ├── config.ex             # Multi-level config precedence
│   │       ├── cache.ex              # TTL + LRU cache
│   │       ├── circuit_breaker.ex    # Circuit breaker state machine
│   │       ├── retry.ex              # Exponential backoff retry
│   │       ├── write_buffer.ex       # Batch write-behind buffer
│   │       └── discovery.ex          # Endpoint auto-discovery
│   ├── pipelines/
│   │   ├── inference_pipeline.ex      # Request → provider → response
│   │   ├── routing_pipeline.ex        # Task type → resolved route
│   │   └── memory_pipeline.ex         # Hindsight operation orchestration
│   ├── provider/
│   │   ├── definition.ex              # Provider metadata struct
│   │   └── registry.ex               # ETS provider lookup
│   ├── router/
│   │   ├── router.ex                  # Router GenServer
│   │   └── structs.ex                # RouteEntry, RoutingTable, ResolvedRoute
│   ├── structured/
│   │   ├── instructor_adapter.ex     # Instructor integration adapter
│   │   ├── json_mode.ex             # JSON decode/enforce helpers
│   │   └── validator.ex             # Schema validation dispatcher
│   └── telemetry/
│       ├── settings.ex               # Telemetry config (sample rate, etc.)
│       └── logger.ex                 # Telemetry → Logger handler
└── mix/tasks/
    ├── llm_core.bench.ex             # Benchmark mix task
    ├── llm_core.config.set.ex        # Config mutation mix task
    ├── llm_core.config.show.ex       # Config display mix task
    └── llm_core.config.validate.ex   # Config validation mix task
```

## Supervision Tree

```
LlmCore.Supervisor (one_for_one)
├── LlmCore.Config.Store          (ETS owner)
├── LlmCore.Agent.Registry        (GenServer)
├── LlmCore.Router                (GenServer)
├── LlmCore.Config.Watcher        (GenServer, optional)
└── LlmCore.Memory.Hindsight.Supervisor (one_for_one, optional)
    ├── Hindsight.Cache            (GenServer + ETS)
    ├── Hindsight.WriteBuffer      (GenServer)
    ├── Hindsight.CircuitBreaker   (GenServer)
    └── Task (startup_sequence)    (discovery + prefetch + health monitor)
```

## Key Design Decisions

1. **ALF pipelines over GenServer chains** — Declarative stage composition
   with built-in telemetry, easier to reason about and extend.

2. **Provider behaviour, not protocol** — Behaviours give compile-time
   checking and clear callback contracts; protocols would add dispatch
   overhead without benefit for a fixed adapter set.

3. **ETS for hot config** — Routing tables and provider metadata live in ETS
   for lock-free reads. The file watcher triggers reloads into ETS.

4. **Write-behind buffer for Hindsight** — Retain operations are
   non-blocking; the buffer batches and flushes, persisting to disk on
   shutdown to prevent data loss.

5. **Circuit breaker + cache + retry** — Three-layer resilience ensures
   Hindsight failures don't cascade into the main request path. Stale cache
   values are served while background refreshes happen.

6. **CLI providers via Port** — Using Erlang ports instead of System.cmd
   enables streaming output capture and HALT/interrupt semantics for
   long-running CLI operations.
