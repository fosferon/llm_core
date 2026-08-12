# LlmCore

> Provider-agnostic LLM orchestration for Elixir. Route to any model, run agentic loops, extract structured output, and connect to semantic memory, all through composable ALF pipelines with hot-reload TOML configuration.

LlmCore is the shared LLM substrate that powers the [Fosferon](https://github.com/fosferon) ecosystem. It handles the messy parts of working with LLMs — provider routing, CLI wrapping, structured extraction, tool-calling loops, and pluggable semantic memory integration — so your application code stays clean.

## Why LlmCore?

- **One API, every provider.** Cloud APIs (Anthropic, OpenAI, Z.ai), local inference (Ollama, DGX Spark), and CLI tools (Claude Code, Gemini CLI, Codex, Droid, Kimi) all share the same `Provider` behaviour. Route by task type, fall back gracefully, add new providers without writing Elixir.

- **Config-driven CLI providers.** Adding a new CLI tool is a TOML block — no Elixir code needed. Declare the binary, flags, prompt transport, system prompt strategy, and output normalization. LlmCore handles the rest.

- **In-process agentic loops.** `LlmCore.Agent.Loop` runs tool-calling iterations inside the BEAM VM — no subprocess, no CLI overhead. Built-in circuit breaking detects stuck loops. Uses any API provider that supports tool use.

- **Hot-reload TOML configuration.** Change providers, routing rules, and memory settings without restarting. File watcher with debouncing keeps the runtime store (`ETS`) in sync with disk.

- **Structured output without the weight.** JSON-mode extraction and schema validation built in. No Instructor dependency. Custom validators via functions.

- **Pluggable semantic memory.** Resilient Hindsight and Foresight integrations with caching, circuit breaker, retry with backoff, and write buffering. Store once, recall by meaning.

- **Observable by default.** Every operation emits `:telemetry` events. Pipeline spans, provider dispatch, router decisions, memory operations — all instrumented.

## Installation

Add `llm_core` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:llm_core, "~> 0.6"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### Send a prompt through the router

```elixir
# Routes automatically based on [routing.tasks] config
{:ok, response} = LlmCore.send("Explain pattern matching in Elixir", :reasoning)
IO.puts(response.content)
```

### Stream a response

```elixir
{:ok, stream} = LlmCore.stream("Write a GenServer example", :coding)
Enum.each(stream, fn chunk -> IO.write(chunk) end)
```

### Extract structured output

```elixir
schema = %{
  type: "object",
  properties: %{
    name: %{type: "string"},
    confidence: %{type: "number"}
  },
  required: ["name"]
}

{:ok, response} = LlmCore.send("Analyze this code", :reasoning,
  response_format: {:json_schema, schema}
)

response.structured
#=> %{"name" => "authenticate/2", "confidence" => 0.92}
```

### Run an agentic tool-calling loop

```elixir
alias LlmCore.Agent.Loop

tools = MyApp.Tools.available()
resolve = &MyApp.Tools.resolve/1

llm_send = fn messages, opts ->
  LlmCore.LLM.Provider.dispatch(LlmCore.LLM.Anthropic, messages, opts)
end

{:ok, response, messages} =
  Loop.run(
    [%{role: :user, content: "Research Elixir ALF"}],
    llm_send,
    tools: tools,
    resolve_tool: resolve,
    max_iterations: 10
  )
```

### Semantic memory

LlmCore supports [Hindsight](https://github.com/vectorize-io/hindsight) and
Foresight through one API. Hindsight REST remains the default. The HTTP
backends share caching, circuit breaking, retry with backoff, and write
buffering.

```elixir
# Store a fact (async, buffered)
:ok = LlmCore.retain("Schema-per-tenant isolation pattern", %{context: "architecture"})

# Recall by meaning
{:ok, results} = LlmCore.recall("how does multi-tenancy work?", bank_id: "my-bank")

# Synthesize an insight
{:ok, insight} = LlmCore.reflect("What patterns are most effective?", bank_id: "my-bank")
```

Select a backend in `llm_core.toml`:

```toml
[memory]
backend = "foresight_http" # hindsight_rest | foresight_http | foresight_inprocess

[memory.foresight_http]
url = "http://localhost:4012"
default_bank_id = "my-bank"
```

For `foresight_inprocess`, the consuming application must depend on Foresight
and start `Foresight.Supervisor`. LlmCore resolves the optional integration at
runtime, avoiding a circular package dependency.

### Query available providers

```elixir
# All configured providers
providers = LlmCore.Provider.Registry.all()

# Only available ones (API keys present, binaries in PATH)
available = LlmCore.Provider.Registry.available()

# Find by alias
{:ok, provider} = LlmCore.Provider.Registry.lookup_alias("claude")

# Fuzzy suggestions (Jaro distance)
LlmCore.Provider.Registry.suggest_alias("claud")
#=> ["claude"]

# Capable providers for requirements
LlmCore.Provider.Registry.suggest_capable(%{streaming: true, tool_use: true})
```

### CLI provider discovery

```elixir
# List all CLI providers (built-in + configured)
entries = LlmCore.CLIProvider.Registry.list()

# Only those with binary in PATH
available = LlmCore.CLIProvider.Registry.available()

# Resolve by id or alias
{:ok, provider} = LlmCore.CLIProvider.Registry.resolve(:droid)

# Check capabilities
{:ok, caps} = LlmCore.CLIProvider.Registry.capabilities(:codex_cli)
```

## Configuration

LlmCore uses layered TOML configuration. Later sources override earlier ones:

```
1. Compiled defaults    (priv/config/llm_core.toml)
2. Global override      (~/.llm_core/config/llm_core.toml)
3. Project override     (<project>/.llm_core/llm_core.toml)
4. Environment variable (LLM_CORE_CONFIG=path)
5. Custom path          (explicit :path option)
6. Runtime overrides    (ETS, via mix tasks or API)
```

### Minimal configuration

```toml
[routing]
default = "claude"

[providers.anthropic]
module = "LlmCore.LLM.Anthropic"
aliases = ["claude"]

[providers.anthropic.auth]
api_key_env = "ANTHROPIC_API_KEY"
```

### Task-based routing

```toml
[routing]
default = "claude"

[routing.tasks.coding]
alias = "openai"
mode = "passthrough"
capabilities = { structured_output = true, tool_use = true }

[routing.tasks.planning]
alias = "claude"
mode = "abstracted"
capabilities = { reasoning = true }
```

### Add a CLI provider (no code needed)

```toml
[providers.my_tool]
type = "cli"
enabled = true
aliases = ["my-tool", "mt"]

[providers.my_tool.cli]
binary = "my-tool"
default_model = "v2"
default_timeout = 60000
prompt_position = "last"
install_hint = "pip install my-tool"
auto_approve_args = ["--yes"]

[providers.my_tool.cli.flags]
model = "--model"
temperature = "--temp"

[providers.my_tool.cli.preflight]
help_args = ["--help"]
expect_in_help = ["--model"]
```

### Mix task helpers

```bash
# Inspect configuration
mix llm_core.config.show
mix llm_core.config.show --section providers --json

# Edit configuration
mix llm_core.config.set --path routing.default.alias --value claude
mix llm_core.config.set --path telemetry.sample_rate --value 0.25 --type float

# Validate configuration
mix llm_core.config.validate
```

See the [Configuration Guide](https://hexdocs.pm/llm_core/configuration.html) for the full TOML schema, environment variable interpolation, and agent registration rules.

## Architecture

LlmCore is built on [ALF](https://github.com/antonmi/alf) (Antonmi's Flow-based Framework) for composable, observable data pipelines:

```
┌─────────────────────────────────────────────────────────────┐
│                       LlmCore                                │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │  Inference   │  │   Routing    │  │   Hindsight        │ │
│  │  Pipeline    │  │   Pipeline   │  │   Memory Client    │ │
│  └──────────────┘  └──────────────┘  └────────────────────┘ │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │  Agent Loop  │  │   Config     │  │   Telemetry        │ │
│  │  (Tool Use)  │  │   (Hot TOML) │  │   (Observable)     │ │
│  └──────────────┘  └──────────────┘  └────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

Three ALF pipelines handle the core flows:

- **Inference Pipeline** — normalize request → resolve route → check capabilities → dispatch provider → apply structured output → emit telemetry
- **Routing Pipeline** — parse task type → load routing config → match rules → resolve agent or apply fallback
- **Memory Pipeline** — route operation (retain/recall/reflect) → circuit breaker gate → retry with backoff → update cache

See the [Architecture Guide](https://hexdocs.pm/llm_core/architecture.html) for pipeline internals, provider behaviour contracts, and the agent loop design.

## Telemetry Events

```elixir
# Provider dispatch
[:llm_core, :provider, :send, :start | :stop | :exception]
[:llm_core, :provider, :stream, :start | :chunk | :stop]

# Router decisions
[:llm_core, :router, :resolve, :start | :stop]
[:llm_core, :router, :fallback]

# Agent loop
[:llm_core, :agent, :complete]

# Memory operations
[:llm_core, :hindsight, :retain | :recall | :reflect]
[:llm_core, :hindsight, :circuit_breaker, :state_change]

# Configuration
[:llm_core, :config, :reload]
```

## Built-in Providers

| Provider | Type | Module | Key Capabilities |
|----------|------|--------|-----------------|
| Anthropic | API | `LlmCore.LLM.Anthropic` | Streaming, tool use, vision, structured output |
| OpenAI | API | `LlmCore.LLM.OpenAI` | Streaming, tool use, vision, structured output |
| Ollama | Local | `LlmCore.LLM.Ollama` | Streaming, JSON mode, local models |
| Appliance | Local | `LlmCore.LLM.Appliance` | OpenAI-compatible local endpoints |
| Native | API | `LlmCore.LLM.Native` | In-process agentic loop with cascade fallback |
| Claude Code | CLI | Config-driven | `--print`, system prompt file, auto-approve |
| Droid | CLI | Config-driven | `exec` subcommand, `--auto`, `--cwd` |
| Pi CLI | CLI | Config-driven | `--print`, `--provider`, `--thinking` |
| Kimi CLI | CLI | Config-driven | Agent-file YAML transform, final-message capture |
| Codex CLI | CLI | Config-driven | `--full-auto`, file capture, sandbox bypass |
| Gemini CLI | CLI | Config-driven | Model selection |

## Documentation

- [Configuration Guide](https://hexdocs.pm/llm_core/configuration.html) — Full TOML schema, layered config, mix tasks
- [Architecture Guide](https://hexdocs.pm/llm_core/architecture.html) — Pipeline design, provider system, memory integration
- [CLI Providers](https://hexdocs.pm/llm_core/cli-providers.html) — Adding and configuring CLI-based providers
- [Agent Loop](https://hexdocs.pm/llm_core/agent-loop.html) — Tool-calling loops, context, pipeline stages

## License

MIT — see the [LICENSE](https://github.com/fosferon/llm_core/blob/main/LICENSE) file.
