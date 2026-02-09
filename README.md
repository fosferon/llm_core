# LlmCore

Provider-agnostic LLM orchestration library for Elixir. Route prompts to the
right model, extract structured output, and access semantic memory — all through
composable ALF pipelines with hot-reload configuration.

## Features

- **Multi-provider support** — Anthropic, OpenAI, Ollama, Claude Code CLI, Gemini CLI
- **ALF pipelines** — Composable inference, routing, and memory pipelines with
  backpressure and streaming
- **Hot-reload configuration** — TOML-based config with file watching, environment
  variable interpolation, and layered overrides
- **Structured output** — JSON-mode extraction and schema validation without heavy
  dependencies
- **Semantic memory** — Resilient Hindsight MCP client with caching, circuit breaker,
  retry, and write buffering
- **Intelligent routing** — Task-type based routing with capability matching and
  fallback chains
- **Telemetry** — Observable pipelines with `:telemetry` events for every operation

## Supported Providers

| Provider | Type | Features |
|----------|------|----------|
| Anthropic | Cloud API | Streaming, tool use, vision |
| OpenAI | Cloud API | Streaming, structured output, tool use |
| Ollama | Local | Streaming, JSON mode, model management |
| Claude Code | CLI | Passthrough to Claude Code CLI |
| Gemini CLI | CLI | Passthrough to Gemini CLI |

## Installation

Add `llm_core` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:llm_core, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Send a prompt through the inference pipeline
{:ok, response} = LlmCore.send("Explain pattern matching in Elixir", task: :reasoning)

# Stream a response
{:ok, stream} = LlmCore.stream("Write a GenServer example", task: :coding)

# Extract structured output
{:ok, response} = LlmCore.send(prompt, response_format: {:json_schema, schema})

# Semantic memory
:ok = LlmCore.Memory.Hindsight.retain("learned something", %{type: :insight})
{:ok, results} = LlmCore.Memory.Hindsight.recall("pattern matching")
```

## Configuration

llm_core uses layered TOML configuration:

```toml
[providers.anthropic]
module = "LlmCore.LLM.Anthropic"
aliases = ["claude"]

[providers.anthropic.auth]
api_key_env = "ANTHROPIC_API_KEY"

[routing]
default = "claude"

[routing.tasks.coding]
alias = "ollama"
```

See the [Configuration Guide](docs/configuration.md) for full details.

## Documentation

- [Configuration Guide](docs/configuration.md) — Layered config, TOML schema, mix tasks
- [Architecture](docs/architecture.md) — Pipeline design, provider system, memory integration

## License

MIT — see [LICENSE](LICENSE).
