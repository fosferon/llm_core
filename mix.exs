defmodule LlmCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :llm_core,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {LlmCore.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:file_system, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:typed_struct, "~> 0.3"},
      {:alf, "~> 0.12"},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
