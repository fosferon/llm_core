defmodule LlmCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fosferon/llm_core"

  def project do
    [
      app: :llm_core,
      version: @version,
      elixir: "~> 1.17",
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
    "Provider-agnostic LLM orchestration library for Elixir with ALF pipelines, " <>
      "hot-reload configuration, structured output, and semantic memory."
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
      extras: ["README.md", "docs/configuration.md", "docs/architecture.md"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:toml, "~> 0.7"},
      {:file_system, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:typed_struct, "~> 0.3"},
      {:alf, "~> 0.12"},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:comm_bus, git: "https://github.com/fosferon/comm_bus.git"}
    ]
  end
end
