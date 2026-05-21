# CLI Providers

LlmCore can wrap any command-line LLM tool as a first-class provider. No Elixir code needed — just TOML configuration.

## How It Works

CLI providers are declared in TOML with `type = "cli"`. At runtime, `LlmCore.LLM.CLIProvider` builds the correct command-line invocation from the config: binary, flags, prompt position, system prompt strategy, output capture, and error handling.

A CLI provider is considered **available** when:
1. `enabled = true` in its config block
2. The declared `binary` is found in `PATH`

No API key or module loading required.

## Built-in CLI Providers

These ship in `priv/config/llm_core.toml` and work out of the box when the binary is installed:

| Name | Binary | Highlights |
|------|--------|------------|
| `claude_code` | `claude` | `--print`, system prompt via `--append-system-prompt-file`, `--add-dir` |
| `droid` | `droid` | `exec` subcommand, `--auto high`, `--cwd`, `--worktree` |
| `pi_cli` | `pi` | `--print`, `--provider`, `--thinking`, system prompt file |
| `kimi_cli` | `kimi-cli` | Agent-file YAML transform, `--final-message-only`, output stripping |
| `codex_cli` | `codex` | `exec` subcommand, `--full-auto`, file capture via `--output-last-message` |
| `gemini_cli` | `gemini` | Model selection, standard CLI interface |

To **override** a built-in, define a `[providers.<name>]` block with the same ID and `type = "cli"` in a project or global TOML override. Your definition replaces the default entirely.

## Adding a Custom CLI Provider

Here is a complete example:

```toml
[providers.my_tool]
type = "cli"
enabled = true
aliases = ["my-tool", "mt"]
default_model = "v2"

[providers.my_tool.cli]
binary = "my-tool"                     # required — must be in PATH
subcommand = "exec"                    # optional subcommand prepended to args
default_timeout = 60000                # ms (default: 1_800_000 = 30 min)
prompt_position = "last"              # "last" or "flagged"
prompt_transport = "last"             # "last", "flagged", or "stdin"
system_prompt_transport = "file_flag"  # "flag", "file_flag", "inline_fallback", or "unsupported"
install_hint = "pip install my-tool"   # shown when binary is missing
prefix_args = ["--no-interactive"]     # always prepended
auto_approve_args = ["--yes"]          # appended when auto_approve: true
sandbox_bypass_args = ["--unsafe"]     # appended when sandbox_bypass: true

[providers.my_tool.cli.flags]
model = "--model"
temperature = "--temp"
system_prompt = "--system-prompt"
system_prompt_file = "--system-file"
cwd = "--cwd"

[providers.my_tool.cli.preflight]
help_args = ["--help"]
expect_in_help = ["--model"]

[providers.my_tool.capabilities]
streaming = true
passthrough = true

[providers.my_tool.metadata]
cost_tier = "cli"
```

## Configuration Reference

### Core Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `binary` | **Yes** | — | Executable name, must be in PATH |
| `subcommand` | No | `nil` | Subcommand prepended before flags (e.g. `"exec"` for `droid exec`) |
| `default_timeout` | No | `1800000` (30 min) | Process timeout in milliseconds |
| `default_model` | No | `nil` | Model string passed to `--model` |
| `model_resolution` | No | `"provider_runtime"` | How model selection works: `"gc_default"`, `"provider_runtime"`, or `"explicit_only"` |
| `prompt_position` | No | `"last"` | Where the prompt goes: `"last"` (end of args) or `"flagged"` (after `prompt_flag`) |
| `prompt_flag` | Conditional | `nil` | Required when `prompt_position = "flagged"` (e.g. `"-p"` for Claude) |
| `prompt_transport` | No | follows `prompt_position` | Semantic transport: `"last"`, `"flagged"`, or `"stdin"` |
| `stdin_hack` | No | `false` | Wrap with `/bin/sh -c ... < /dev/null` (needed by Claude CLI) |
| `prefix_args` | No | `[]` | Arguments always prepended (e.g. `["--print"]`) |
| `install_hint` | No | `nil` | Human-readable message shown when binary is not found |

### Automation Args

These three profiles let callers control the CLI's autonomy level:

| Field | Purpose |
|-------|---------|
| `non_interactive_args` | Enable batch mode (e.g. `["--batch"]`) |
| `auto_approve_args` | Enable unattended execution (e.g. `["--auto", "high"]`) |
| `sandbox_bypass_args` | Disable approval/sandbox entirely (e.g. `["--dangerously-bypass-approvals-and-sandbox"]`) |

All are appended to the invocation only when the corresponding option is `true` in the dispatch call.

### System Prompt Transport

How the system prompt reaches the CLI:

| Transport | Behavior |
|-----------|----------|
| `"flag"` | Passed via a flag like `--system-prompt "text"` |
| `"file_flag"` | Written to a temp file, path passed via `--system-file /tmp/...` |
| `"inline_fallback"` | Prepended to the user prompt as `System instructions:\n...\nUser request:\n...` |
| `"unsupported"` | No system prompt mechanism available |

### System Prompt File Transforms

Some CLIs need the system prompt in a specific file format. Declare the transform:

```toml
[providers.kimi_cli.cli]
system_prompt_file_transform = "agent_spec_yaml"

[providers.kimi_cli.cli.file_transform_defaults]
version = 1
extend = "default"
```

Supported transforms:
- `"agent_spec_yaml"` — Generates a YAML agent spec + sibling `system.md`. Used by Kimi CLI's `--agent-file`.

### Output Capture

| Field | Purpose |
|-------|---------|
| `output_mode` | How to capture output: `"stdout_text"` (default), `"final_message_only"`, or `"json"` |
| `output_file_flag` | CLI flag that writes the final response to a file (e.g. `"--output-last-message"` for Codex) |
| `output_strip_patterns` | Regex patterns stripped from stdout before building the response |

### JSONL Event Extraction

Some CLIs emit structured JSON events (one per line) to stdout. When `output_mode = "json"` and `output_event_format = "jsonl"`, LlmCore parses each line, selects matching events, and concatenates text chunks into a single response. If no events match, raw stdout is used as a fallback.

```toml
[providers.my_tool.cli]
output_mode = "json"
output_event_format = "jsonl"

# Select events where type == "assistant" and role == "text"
[providers.my_tool.cli.output_event_select]
type = "assistant"
role = "text"

# Navigate into the JSON object to find the text content
# e.g. {"type":"assistant","message":{"content":"Hello"}}
# would use output_event_text_path = ["message", "content"]
output_event_text_path = ["message", "content"]
```

| Field | Required | Description |
|-------|----------|-------------|
| `output_event_format` | No | Currently only `"jsonl"` is supported. Activates line-by-line JSON parsing when `output_mode` is `"json"`. |
| `output_event_select` | No | Map of key-value pairs. An event must match **all** entries to be selected. |
| `output_event_text_path` | No | List of keys to navigate into the event JSON and extract the text string. |

ANSI escape codes are stripped from each line before JSON parsing. Non-JSON lines and lines that don't match the selector are silently skipped.

### Preflight Checks

Declarative validation that the CLI binary matches the configured contract:

```toml
[providers.my_tool.cli.preflight]
help_args = ["--help"]
expect_in_help = ["--model"]
```

Runs the binary with `help_args`, checks that every string in `expect_in_help` appears in the output. Fails fast if the CLI version doesn't support expected flags.

### Flags Map

Maps semantic option keys to CLI flag strings:

```toml
[providers.my_tool.cli.flags]
model = "--model"
temperature = "--temp"
```

At dispatch time, these are resolved: `model: "v2"` becomes `--model v2` in the invocation. Boolean flags work too: `auto_approve: true` becomes just `--auto` (no value).

## Querying at Runtime

```elixir
alias LlmCore.CLIProvider.Registry

# All known CLI providers (built-in + configured)
Registry.list()
#=> [%{id: :claude_code, aliases: ["claude-code"], binary: "claude", available?: true, ...}, ...]

# Only those with binary in PATH
Registry.available()

# Fetch by id or alias
{:ok, entry} = Registry.fetch(:droid)
{:ok, entry} = Registry.fetch("pi")

# Get a ready-to-use provider struct
{:ok, provider} = Registry.resolve(:claude_code)

# Inspect capabilities
{:ok, caps} = Registry.capabilities(:codex_cli)
#=> %{streaming: true, passthrough: true, ...}
```

## Validation Rules

- `binary` is required and must be a non-empty string
- `prompt_position = "flagged"` requires `prompt_flag` to be set
- Enum fields are validated: `prompt_position`, `prompt_transport`, `system_prompt_transport`, `output_mode`, `output_event_format`, `system_prompt_file_transform`
- `default_model` must be a real model identifier, not a provider name or binary name
- Invalid configs are skipped with a warning (same as module providers)
