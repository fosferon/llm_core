defmodule LlmCore.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/fosferon/llm_core"

  def project do
    [
      app: :llm_core,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {LlmCore.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp description do
    "Provider-agnostic LLM orchestration for Elixir. " <>
      "Composable ALF pipelines, hot-reload TOML config, CLI provider support, " <>
      "in-process agentic loops, structured output, and semantic memory."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/configuration.md",
        "docs/architecture.md",
        "docs/cli-providers.md",
        "docs/agent-loop.md"
      ],
      groups_for_modules: [
        "Public API": [LlmCore],
        Providers: [LlmCore.LLM.Provider, LlmCore.LLM.CLIProvider, LlmCore.LLM.Response, LlmCore.LLM.Error],
        Routing: [LlmCore.Router, LlmCore.Router.ResolvedRoute, LlmCore.Router.RoutingTable, LlmCore.Router.RouteEntry],
        Configuration: [LlmCore.Config.Store, LlmCore.Config.Loader, LlmCore.Config.Watcher],
        "Agent Loop": [LlmCore.Agent, LlmCore.Agent.Loop, LlmCore.Agent.Context, LlmCore.Agent.Registry],
        "Structured Output": [LlmCore.Structured],
        Memory: [LlmCore.Memory.Hindsight],
        Registries: [LlmCore.Provider.Registry, LlmCore.Provider.Definition, LlmCore.CLIProvider.Registry],
        Pipelines: [LlmCore.Pipelines.InferencePipeline, LlmCore.Pipelines.RoutingPipeline, LlmCore.Pipelines.MemoryPipeline]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Tool contract + base tools (ToolResolver, Tool, Call, Result)
      {:llm_toolkit, "~> 0.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:toml, "~> 0.7"},
      {:file_system, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:typed_struct, "~> 0.3"},
      {:alf, "~> 0.12"},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false},
      {:earmark, "~> 1.4", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:comm_bus, "~> 0.1"}
    ]
  end
end
