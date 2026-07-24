# Changelog

All notable changes to this project will be documented in this file.

## 0.6.0 — 2026-07-24

### Added
- `LlmCore.Memory.Backend` and the backend-neutral `LlmCore.Memory` facade.
- Configurable `hindsight_rest`, `foresight_http`, and optional
  `foresight_inprocess` memory backends. The two HTTP backends share the
  existing cache, circuit breaker, retry, and write-buffer implementation.

### Changed
- `LlmCore.Memory.Hindsight` is deprecated in favor of `LlmCore.Memory` and
  remains as a compatibility facade for one release.
- The default memory backend remains Hindsight REST, so existing consumers
  require no configuration or code changes.

## 0.5.0 — 2026-07-19

### Added
- `LlmCore.Agent.Loop.run/3` accepts a `:terminal_tool` option: a tool name
  that, when the model calls it, ends the loop **without dispatching** the
  call. This lets the model nominate a structured result as its final turn
  (for example, selecting reflect citations). The raw arguments are attached
  to `response.metadata.terminal_args`, and the full call object to
  `response.metadata.terminal_tool_call`. Corresponding fields
  (`terminal_tool`, `terminal_tool_call`, `terminal_args`) are carried on
  `LlmCore.Agent.Context` for downstream inspection.

## 0.4.4 — 2026-07-18

### Fixed
- Agentic tool-calling conversations now serialize correctly for both the
  OpenAI and Anthropic wire formats.
  `LlmCore.LLM.Messages.normalize_chat/1` preserves `tool_calls` on assistant
  messages and guarantees `function.arguments` is a JSON string as Chat
  Completions requires — including when a caller passes already-wire-shaped
  calls whose `arguments` is a decoded map. `valid_message?/1` validates the
  tool-call structure (a pure tool-call turn is accepted even when content is
  nil/absent) and filters malformed calls instead of crashing.
- `LlmCore.LLM.Anthropic.build_payload/1` now converts assistant `tool_calls`
  into Anthropic native `tool_use` content blocks, paired with the following
  `tool_result`, so multi-turn tool-calling conversations round-trip through
  the Anthropic API. Previously they were sent in OpenAI shape and rejected —
  surfacing via OpenRouter as the misleading "This model does not support
  assistant message prefill" 400, which failed every tool-invoking turn.

## 0.4.3 — 2026-07-17

### Fixed
- `LlmCore.LLM.Messages.normalize_chat/1` no longer drops `tool_calls` from
  assistant messages. The generic role/content clause matched an assistant
  message carrying `tool_calls` and kept only role+content, silently discarding
  the calls. On a tool-call continuation this sent the following `tool` result
  to the wire orphaned (a tool_result with no preceding tool_use), so providers
  rejected the whole conversation — via OpenRouter → Anthropic surfacing as the
  misleading "This model does not support assistant message prefill" 400, which
  failed every tool-invoking turn. Assistant `tool_calls` are now preserved and
  serialized to OpenAI wire shape (`[{id, type: "function", function: {name,
  arguments}}]`, arguments JSON-encoded). `valid_message?/1` also accepts an
  assistant message carrying `tool_calls` when its content is nil/absent, so a
  pure tool-call turn survives filtering.

## 0.4.0 — 2026-05-21

### Added
- JSONL event output extraction for CLI providers (`output_event_format`,
  `output_event_select`, `output_event_text_path`). When a CLI emits
  structured JSON events to stdout, LlmCore can now parse them line by
  line, select matching events, and concatenate text chunks into a
  response — with automatic fallback to raw stdout.
- Documented JSONL event extraction in the CLI Providers guide.

## 0.3.2 — 2026-05-14

### Fixed
- Proper fix for shared-module provider availability (e.g. `zai` backed by
  `LlmCore.LLM.OpenAI` with a custom `api_key_env`). Adds an optional
  `available?/1` callback to `LlmCore.LLM.Provider` that receives the
  TOML-resolved auth map, so the correct env var is checked instead of the
  module's hardcoded default. Providers that perform health checks (Ollama,
  Appliance) are unaffected — they keep using `available?/0`.

## 0.3.1 — 2026-05-11

### Fixed
- `LlmCore.Pipelines.RoutingPipeline` no longer returns false `:capability_mismatch`
  errors when multiple provider definitions share a backing module (e.g. `openai`
  and `zai` both backed by `LlmCore.LLM.OpenAI`, or multiple Ollama-backed
  personas). Capability lookup is now keyed by the resolved provider **alias**
  rather than the (non-unique) module.

### Changed
- **Breaking:** `LlmCore.Provider.Registry.lookup_by_module/1` has been replaced
  by `LlmCore.Provider.Registry.lookup_by_alias/1`. The previous function was
  fundamentally ambiguous whenever two definitions shared a module; the alias is
  the unique configuration key and is what callers actually want. The routing
  pipeline (the only in-tree consumer) has been updated accordingly.

## 0.3.0 — 2026-05-09

### Added
- Comprehensive documentation overhaul: README, architecture guide, configuration guide,
  new CLI Providers guide, new Agent Loop guide.
- `ex_doc` and `earmark` as dev dependencies for Hex documentation generation.
- Module grouping in ExDoc for organized API reference.
- Enhanced `@moduledoc` for `LlmCore`, `LlmCore.Router`, `LlmCore.Structured`,
  `LlmCore.Provider.Registry`, `LlmCore.CLIProvider.Registry`, `LlmCore.Config.Store`,
  `LlmCore.Config.Loader`, and `LlmCore.Agent`.

### Changed
- Updated Hex package description to better reflect the library's scope.
- README rewritten as a proper Hex landing page with real usage examples from
  production consumers.

## 0.2.0 — 2026-05-01

### Added
- `LlmCore.Memory.Hindsight` now accepts an optional `:api_key` keyword in `retain/3`, `retain_sync/3`, `recall/2`, `reflect/2`, `create_bank/2`, `delete_bank/2`, `list_banks/1`, and `bank_stats/2`. When provided, the key is sent as `Authorization: Bearer <key>` instead of the globally-configured env-var key. Callers that do not pass `:api_key` continue to use the global key with zero behavior change.

### Changed
- `LlmCore.Memory.Hindsight.WriteBuffer` now partitions buffered items by `api_key` on flush. Each distinct key (including `nil`, which falls back to the global key) results in a separate HTTP POST with the correct `Authorization` header. This enables tenant-aware batch retention where items from different subscribers are sent with their respective credentials.
- **Behavior change:** Removed the localhost auth-skip special case in `WriteBuffer`. Requests to `127.0.0.1:*` URLs now include the `Authorization` header whenever a key is available (global or per-call). This fixes a latent bug where local Hindsight servers requiring authentication (e.g. with a tenant extension) were sent unauthenticated requests.
