# Changelog

All notable changes to this project will be documented in this file.

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
