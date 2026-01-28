defmodule LlmCore.TestProviders.Basic do
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.Response

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: true,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: ["test-basic"],
      max_context: 1000
    }
  end

  @impl true
  def provider_type, do: :api

  @impl true
  def send(prompt, opts \\ []) do
    content =
      if Keyword.has_key?(opts, :response_format) do
        ~s({"echo":"#{render(prompt)}"})
      else
        render(prompt)
      end

    {:ok,
     Response.new(
       content: content,
       provider: :test_basic,
       model: Keyword.get(opts, :model, "test-basic"),
       raw: %{prompt: prompt}
     )}
  end

  @impl true
  def stream(prompt, _opts \\ []) do
    {:ok, Stream.map([render(prompt)], & &1)}
  end

  defp render(prompt) when is_list(prompt), do: inspect(prompt)
  defp render(prompt), do: to_string(prompt)
end

defmodule LlmCore.TestProviders.NoStreaming do
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.Response

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: false,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: ["no-stream"],
      max_context: 100
    }
  end

  @impl true
  def provider_type, do: :api

  @impl true
  def send(prompt, _opts \\ []) do
    {:ok, Response.new(content: to_string(prompt), provider: :no_stream, model: "no-stream")}
  end

  @impl true
  def stream(_prompt, _opts \\ []), do: {:error, :not_supported}
end

defmodule LlmCore.TestProviders.NoStructured do
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.Response

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: true,
      structured_output: false,
      tool_use: false,
      vision: false,
      models: ["no-structured"],
      max_context: 100
    }
  end

  @impl true
  def provider_type, do: :api

  @impl true
  def send(prompt, _opts \\ []) do
    {:ok,
     Response.new(
       content: to_string(prompt),
       provider: :no_structured,
       model: "no-structured"
     )}
  end

  @impl true
  def stream(prompt, opts \\ []) do
    LlmCore.TestProviders.Basic.stream(prompt, opts)
  end
end

defmodule LlmCore.TestProviders.CommBusCapture do
  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.Response

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: false,
      structured_output: false,
      tool_use: false,
      vision: false,
      models: ["commbus-capture"],
      max_context: 1_000
    }
  end

  @impl true
  def provider_type, do: :api

  @impl true
  def send(prompt, opts \\ []) do
    {:ok,
     Response.new(
       content: "ok",
       provider: :commbus_capture,
       model: "commbus-capture",
       metadata: %{prompt: prompt, commbus: Keyword.get(opts, :commbus_packet)}
     )}
  end

  @impl true
  def stream(_prompt, _opts \\ []), do: {:error, :not_supported}
end
