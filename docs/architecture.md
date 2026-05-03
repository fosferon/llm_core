# llm_core Architecture

This document describes the internal architecture of llm_core, a provider-agnostic
LLM orchestration library for Elixir.

---

## Overview

llm_core provides shared LLM infrastructure:

```
┌─────────────────────────────────────────────────────────────┐
│                      llm_core                               │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Providers  │  │   Router    │  │    Hindsight        │ │
│  │  (ALF)      │  │   (ALF)     │  │    (Resilient)      │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Structured │  │   Config    │  │    Telemetry        │ │
│  │  Output     │  │   (Hot)     │  │    (Observable)     │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## ALF Pipelines

The library uses [ALF](https://github.com/antonmi/alf) (Antonmi's Flow-based
Framework) for composable, observable data pipelines. ALF provides:

- **Composable stages** - Each transformation is isolated
- **Streaming support** - `stream/2` for lazy evaluation
- **Observability** - Built-in telemetry hooks
- **Testability** - `sync: true` for deterministic testing
- **Backpressure** - GenStage-based flow control

### Inference Pipeline

The main pipeline for sending prompts to LLM providers:

```
validate_request
     ↓
resolve_provider  ←── Router (task_type → provider)
     ↓
check_availability ←── Provider.available?()
     ↓
┌─[switch]────────────────────────────────────┐
│  :streaming → stream_stage (yield chunks)   │
│  :blocking  → send_stage (wait for full)    │
└─────────────────────────────────────────────┘
     ↓
normalize_response ←── Provider-specific → Response.t()
     ↓
[optional] extract_structured ←── Schema validation
     ↓
emit_telemetry
```

### Routing Pipeline

Resolves which provider and model to use for a given task:

```
parse_task_type
     ↓
load_routing_config ←── Config.Store (ETS)
     ↓
match_rules ←── Priority-ordered rule evaluation
     ↓
┌─[switch]────────────────────────────────────┐
│  {:ok, route} → resolve_agent               │
│  {:error, _}  → apply_fallback              │
└─────────────────────────────────────────────┘
     ↓
build_resolved_route ←── ResolvedRoute.t()
```

### Memory Pipeline (Hindsight)

Handles semantic memory operations with resilience:

```
┌─[switch: operation]────────────────────────────┐
│  :retain  → validate_content → buffer_write    │
│  :recall  → check_cache → query_or_fetch       │
│  :reflect → check_cache → insight_query        │
└────────────────────────────────────────────────┘
     ↓
circuit_breaker_gate ←── Allow/Block based on health
     ↓
┌─[composer: retry_state]────────────────────────┐
│  attempt_operation                             │
│  on_failure → exponential_backoff → retry      │
│  on_success → update_cache → return            │
└────────────────────────────────────────────────┘
     ↓
normalize_result
```

---

## Provider System

### Behaviour Contract

All providers implement `LlmCore.LLM.Provider`:

```elixir
@callback send(prompt(), opts()) :: {:ok, Response.t()} | {:error, Error.t()}
@callback stream(prompt(), opts()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
@callback available?() :: boolean()
@callback capabilities() :: capabilities()
@callback provider_type() :: :local | :api | :cli
```

### Supported Providers

| Provider | Type | Module |
|----------|------|--------|
| Anthropic | `:api` | `LlmCore.LLM.Anthropic` |
| OpenAI | `:api` | `LlmCore.LLM.OpenAI` |
| Ollama | `:local` | `LlmCore.LLM.Ollama` |
| Claude Code | `:cli` | `LlmCore.LLM.ClaudeCode` |
| Gemini CLI | `:cli` | `LlmCore.LLM.GeminiCli` |

### Provider Registry

Providers are registered via TOML configuration. There are two kinds:

#### Module providers (`provider_kind: :module`)
- `module` - The Elixir module implementing the `Provider` behaviour
- `aliases` - Names used by routing rules
- `auth.api_key_env` - Environment variable for API key
- `cost_tier` - Used for error suggestions and routing decisions

#### CLI providers (`provider_kind: :cli`)
- `type = "cli"` - No module required
- `[providers.<id>.cli]` - CLI-specific configuration (binary, flags, transports)
- Config-driven: new CLI providers are added via TOML, no Elixir code needed
- Built-in providers (claude_code, droid, pi_cli, kimi_cli, codex_cli, gemini_cli)
  work without config; TOML entries with the same ID override them
- Availability is determined by binary presence in PATH

### CLI Provider Registry

`LlmCore.CLIProvider.Registry` provides a dedicated query surface for CLI
providers. It merges built-in definitions with TOML-configured ones (TOML wins
on conflict) and exposes:

- `list/0` — all known CLI providers with structured metadata
- `available/0` — only those with binary in PATH
- `fetch/1` — by atom ID or string alias
- `resolve/1` — returns a ready-to-use `%CLIProvider{}` struct
- `capabilities/1` — introspect provider capabilities

This is the recommended API for downstream apps that need to discover or select
CLI providers dynamically, replacing hard-coded provider lists.

---

## Structured Output

`LlmCore.Structured` provides lightweight structured data extraction from LLM
responses without heavy dependencies:

- **JSON mode** - For providers supporting `format: "json"`, extract and validate
- **Schema validation** - Validate decoded JSON against schemas
- **Custom validators** - Accept pluggable validation functions
- **Retry-friendly** - On validation failure, retry with error feedback

---

## Routing System

The router resolves task types to providers based on TOML configuration:

- `routing.default` - Default route entry
- `routing.tasks.<task>` - Task-specific overrides with mode and capability requirements
- Hot-reloads when configuration files change

---

## Hindsight Memory Integration

Hindsight is a semantic memory system accessed via MCP (Model Context Protocol).
The integration includes:

- **Caching** - Stale-while-revalidate with configurable TTL
- **Circuit breaker** - Failure isolation to prevent cascade failures
- **Retry with backoff** - Exponential backoff for transient errors
- **Write buffering** - Async batched writes for performance
- **Bank management** - Support for multiple memory banks

### Configuration Precedence

1. UI runtime override (ETS, session-only)
2. Project config
3. Global config
4. Environment variable (`HINDSIGHT_URL`)
5. Auto-discovered endpoint

---

## Configuration System

### Multi-Level Precedence

```
1. Runtime overrides (ETS)     ← Highest priority
2. Environment variables
3. Project config (<project>/.llm_core/)
4. Global config (~/.llm_core/)
5. Compiled defaults           ← Lowest priority
```

### Hot Reload

Configuration is stored in TOML format. The `LlmCore.Config.Watcher` monitors
config directories for changes and triggers reload with debouncing (100ms window).
The normalized snapshot lives in `LlmCore.Config.Store` (ETS) so the router,
provider registry, and memory pipelines react immediately.

---

## Telemetry Events

```elixir
# Provider events
[:llm_core, :provider, :send, :start]
[:llm_core, :provider, :send, :stop]
[:llm_core, :provider, :send, :exception]
[:llm_core, :provider, :stream, :start]
[:llm_core, :provider, :stream, :chunk]
[:llm_core, :provider, :stream, :stop]

# Router events
[:llm_core, :router, :resolve, :start]
[:llm_core, :router, :resolve, :stop]
[:llm_core, :router, :fallback]

# Hindsight events
[:llm_core, :hindsight, :retain]
[:llm_core, :hindsight, :recall, :start]
[:llm_core, :hindsight, :recall, :stop]
[:llm_core, :hindsight, :circuit_breaker, :state_change]

# Config events
[:llm_core, :config, :reload]
[:llm_core, :config, :watcher, :change]
```

---

## Testing Approach

- **Unit tests** - Each provider in isolation (mocked HTTP), router rule matching,
  config loading/merging, structured output extraction
- **Integration tests** - Provider → Router → Response flow, Hindsight retain/recall,
  config hot-reload, streaming end-to-end
- **Property-based tests** - Routing rule precedence, config merge behavior,
  response normalization across providers
- **Behaviour compliance** - All providers implement the behaviour correctly

Test infrastructure includes `Mox` for mock providers and `StreamData` for
property-based testing.
