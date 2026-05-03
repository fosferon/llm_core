# llm_core Configuration Guide

This document explains how to configure `llm_core`, how the layered TOML file
is merged, and how to inspect or edit runtime settings using the mix tasks.

## Layered sources

Configuration values are merged in the following order (later sources override
earlier ones):

1. **Default template** — `priv/config/llm_core.toml` shipped with the lib (bundled into the build artifact as `<app_priv>/config/llm_core.toml`)
2. **Global override** — `~/.llm_core/config/llm_core.toml`
3. **Project override** — `<project_root>/.llm_core/llm_core.toml`
4. **Environment variable** — path in `LLM_CORE_CONFIG`
5. **Custom** — explicit `:path` option passed to the loader
6. **Runtime overrides** — CLI/session overrides stored in ETS (e.g. Hindsight)

The project root defaults to `File.cwd!()` but can be set via `LLM_CORE_PROJECT_ROOT`.
The project config directory can be overridden entirely with `LLM_CORE_PROJECT_CONFIG`.

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

#### Module-based providers (API, local)

- `module` must implement `LlmCore.LLM.Provider`
- `aliases` are used by routing rules/fuzzy suggestions
- `auth.api_key_env` can be omitted - auto-discovery searches for
  `LLM_CORE_<ALIAS>_API_KEY`, `<PROVIDER_ID>_API_KEY`, and custom entries from
  `auth.discover_env`
- `cost_tier` (or `metadata.cost_tier`) feeds error suggestions when capability
  requirements fail

#### CLI-based providers

CLI providers use `type = "cli"` and do not require a `module` field. The CLI
surface is configured entirely in TOML — no Elixir code needed.

```toml
[providers.my_tool]
type = "cli"
enabled = true
aliases = ["my-tool", "mt"]
default_model = "v2"

[providers.my_tool.cli]
binary = "my-tool"                    # required — must be in PATH
subcommand = "exec"                   # optional subcommand prepended to args
default_timeout = 60000               # ms, default 1_800_000
default_model = "v1"                  # fallback if not set at provider level
prompt_position = "last"              # "last" or "flagged"
prompt_flag = "-p"                    # required when prompt_position = "flagged"
prompt_transport = "flagged"          # "last", "flagged", or "stdin"
system_prompt_transport = "file_flag" # "flag", "file_flag", "inline_fallback", "unsupported"
cwd_flag = "--cwd"                    # optional
add_dir_flag = "--add-dir"            # optional
output_mode = "stdout_text"           # "stdout_text", "final_message_only", "json"
stdin_hack = false                    # wrap with /bin/sh for stdin redirect
install_hint = "pip install my-tool"  # shown when binary is missing
prefix_args = ["--no-interactive"]    # always prepended
auto_approve_args = ["--yes"]         # appended when auto_approve: true
sandbox_bypass_args = []              # appended when sandbox_bypass: true
non_interactive_args = ["--batch"]    # appended when non_interactive: true

# System prompt file transform (optional)
system_prompt_file_transform = "agent_spec_yaml"  # "agent_spec_yaml" or omit

# Default values for the file transform (optional)
[providers.my_tool.cli.file_transform_defaults]
version = 1
extend = "default"

# Output capture (optional)
output_file_flag = "--output-last-message"  # read response from file instead of stdout
output_strip_patterns = ["^Session.*$"]     # regex patterns stripped from stdout output

[providers.my_tool.cli.flags]
model = "--model"
temperature = "--temp"
system_prompt_file = "--agent-file"

[providers.my_tool.cli.preflight]
help_args = ["--help"]
expect_in_help = ["--model"]

[providers.my_tool.capabilities]
streaming = true
passthrough = true

[providers.my_tool.metadata]
cost_tier = "cli"
```

**Default CLI providers** (`claude_code`, `droid`, `pi_cli`, `kimi_cli`,
`codex_cli`, `gemini_cli`) ship in `priv/config/llm_core.toml`. To override
one, define a `[providers.<name>]` block with the same ID and `type = "cli"` in
a project or global override — the TOML definition replaces the default.

**Validation rules:**
- `binary` is required and must be a non-empty string
- `prompt_position = "flagged"` requires `prompt_flag` to be set
- Enum fields are validated: `prompt_position`, `prompt_transport`,
  `system_prompt_transport`, `output_mode`, `system_prompt_file_transform`
- Invalid configs are skipped with a warning (same as module providers)

**System prompt file transforms:**

Some CLIs need the system prompt in a specific format rather than raw markdown.
Use `system_prompt_file_transform` to declare the preparation step:

- `"agent_spec_yaml"` — generates a nested YAML agent spec with a sibling
  `system.md`. Used by Kimi CLI's `--agent-file`. Generates:

  ```yaml
  version: 1
  agent:
    extend: default
    name: <agent_name>
    system_prompt_path: ./system.md
    model: <model>    # when available
  ```

  Field values resolve with this precedence:
  1. **Dispatch opts** — `:agent_name`, `:model` passed by the caller
  2. **`file_transform_defaults`** — provider-level TOML defaults
  3. **Built-in fallbacks** — `name: "llm_core_agent"`, `version: 1`, `extend: "default"`

  Consumers like gc_daemon should pass `:agent_name` and `:model` as opts
  when dispatching to CLI providers that use this transform.

**Output capture and normalization:**

- `output_file_flag` — when set, the runtime creates a temp file, passes it via
  this flag, and reads the final response from the file instead of stdout. Used
  by Codex CLI's `--output-last-message` to bypass session noise.
- `output_strip_patterns` — list of regex patterns applied to stdout output
  before building the response. Strips banners, progress indicators, and
  other non-content noise. Only applies to stdout-based output.

**Availability:** A CLI provider is "available" when `enabled = true` and the
binary is found in `PATH`. No API key or module loading required.

#### Querying CLI providers at runtime

```elixir
# List all CLI providers (built-in + configured)
LlmCore.CLIProvider.Registry.list()

# Only those with binary in PATH
LlmCore.CLIProvider.Registry.available()

# Fetch by id or alias
{:ok, entry} = LlmCore.CLIProvider.Registry.fetch(:droid)
{:ok, entry} = LlmCore.CLIProvider.Registry.fetch("pi")

# Get a ready-to-use provider struct
{:ok, provider} = LlmCore.CLIProvider.Registry.resolve(:droid)

# Inspect capabilities
{:ok, caps} = LlmCore.CLIProvider.Registry.capabilities(:codex_cli)
```

Each entry includes: `id`, `aliases`, `binary`, `available?`, `install_hint`,
`default_model`, `capabilities`, `supports_auto_approve?`,
`supports_sandbox_bypass?`, `supports_system_prompt_file?`, `supports_cwd?`,
`supports_add_dir?`, `metadata`.

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

## Agent registration

When providers are loaded from TOML, `LlmCore.Agent.Registry` automatically
creates agent entries so you can look them up by name via
`LlmCore.Agent.Registry.get("claude")`.

### Agents are keyed by aliases, not agent name

Each provider block can declare an `agent.name`, but agents are registered under
the provider's **aliases**, not the agent name. The `agent.name` field is only
used as a fallback when `aliases` is empty.

```toml
[providers.anthropic]
aliases = ["anthropic", "claude"]   # ← agents registered under these

[providers.anthropic.agent]
name = "my-claude"                  # ← NOT used as a registration key
config = {model = "claude-3-5-sonnet"}
```

With the above config:

```elixir
{:ok, _} = LlmCore.Agent.Registry.get("claude")       # works
{:ok, _} = LlmCore.Agent.Registry.get("anthropic")     # works
{:error, :not_found} = LlmCore.Agent.Registry.get("my-claude")  # not found
```

If you need a custom lookup name, add it to `aliases` instead.

### Name validation

Agent names (aliases) must match `^[a-z0-9][a-z0-9_-]*$` — lowercase
alphanumeric, dashes, and underscores only. Names that fail validation are
**silently skipped** during registration. If an alias in your TOML contains
uppercase letters, spaces, or special characters, no agent will be created for
it and no warning will be logged.

### Startup timing

The supervision tree starts `Config.Store` and `Agent.Registry` before loading
TOML configuration. During `init`, the registry sees an empty store and
populates itself from a hardcoded fallback list. Immediately after supervision
startup, `reload_providers/0` loads the full TOML chain (including project-level
overrides) and sends a sync message to the registry. By the time any consumer
code runs, the registry reflects the TOML configuration.

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
