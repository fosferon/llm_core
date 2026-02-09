# llm_core Configuration Guide

This document explains how to configure `llm_core`, how the layered TOML file
is merged, and how to inspect or edit runtime settings using the mix tasks.

## Layered sources

Configuration values are merged in the following order (later sources override
earlier ones):

1. **Default template** - `config/llm_core.toml` shipped with the lib
2. **Global override** - `~/.llm_core/llm_core.toml`
3. **Project override** - `<project>/config/llm_core.toml`
4. **Environment variables** - `${VAR}` references inside the TOML
5. **Runtime overrides** - CLI/session overrides stored in ETS (e.g. Hindsight)

The loader keeps a normalized snapshot inside `LlmCore.Config.Store` so the
router, provider registry, and memory pipelines can react to hot reload events.

## TOML schema highlights

```toml
[providers.anthropic]
module = "LlmCore.LLM.Anthropic"
type = "cloud"
aliases = ["claude", "claude-sonnet"]
default_model = "claude-3-sonnet"
cost_tier = "premium"

[providers.anthropic.auth]
api_key_env = "ANTHROPIC_API_KEY"
discover_env = ["LLM_CORE_ANTHROPIC", "DEV_ANYSCALE"]

[routing]
default = "claude"

[routing.tasks.coding]
alias = "openai"
mode = "passthrough"
capabilities = { structured_output = true, tool_use = true }

[memory.hindsight]
default_bank_id = "${HINDSIGHT_DEFAULT_BANK}"
cache_ttl_ms = 300000

[telemetry]
log_pipeline_events = true
log_provider_dispatch = true
sample_rate = 1.0
enable_logger = true
logger_level = "info"
```

### Provider blocks

- `module` must implement `LlmCore.LLM.Provider`
- `aliases` are used by routing rules/fuzzy suggestions
- `auth.api_key_env` can be omitted - auto-discovery searches for
  `LLM_CORE_<ALIAS>_API_KEY`, `<PROVIDER_ID>_API_KEY`, and custom entries from
  `auth.discover_env`
- `cost_tier` (or `metadata.cost_tier`) feeds error suggestions when capability
  requirements fail

### Routing blocks

- `routing.default` is a `RouteEntry`
- `routing.tasks.<task>` entries can specify `mode` and capability requirements
  that the pipeline validates before invoking a provider

### Memory settings

The `[memory.hindsight]` section feeds runtime overrides. Any key in the struct
(`timeout_*`, `cache_*`, `retain_raw_llm`, `default_bank_id`) can be set here or
via `HINDSIGHT_*` env vars.

## Mix task helpers

### Inspecting configuration

```bash
mix llm_core.config.show                   # summary view
mix llm_core.config.show --section providers
mix llm_core.config.show --section routing --json
```

`--section` accepts `summary`, `providers`, `routing`, `memory`, `telemetry`,
or `raw`. Use `--provider claude` to filter aliases.

### Editing configuration

```bash
mix llm_core.config.set --path routing.default.alias --value claude
mix llm_core.config.set --path memory.hindsight.default_bank_id --value research-bank
mix llm_core.config.set --path telemetry.sample_rate --value 0.25 --type float
```

Values can be supplied as JSON (`--json '{"structured_output":true}'`) and the
task reloads the runtime store by default. Pass `--file <path>` to operate on a
custom TOML file.

## Integrating with your project

1. Drop the generated `config/llm_core.toml` into your project (or symlink to a
   shared copy inside your workspace).
2. Add per-project overrides via
   `mix llm_core.config.set --file config/llm_core.toml ...`.
3. Ensure CI sets the necessary env vars (`ANTHROPIC_API_KEY`, etc.) - the
   auto-discovery will also look for `LLM_CORE_<ALIAS>_API_KEY` to simplify
   local development.
4. Telemetry defaults log pipeline spans to the console; adjust the `telemetry`
   section or run `mix llm_core.config.set --path telemetry.enable_logger --value false --type boolean`
   for quiet environments.
