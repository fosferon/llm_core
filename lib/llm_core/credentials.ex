defmodule LlmCore.Credentials do
  @moduledoc """
  Resolves a credential by the name of the environment variable that holds it.

  By default a credential is read from the OS environment with `System.get_env/1`, which is the behaviour
  of every earlier release. A host application that keeps its credentials elsewhere (for example in an
  in-memory store, so that they never enter the process environment) can supply its own resolver:

      config :llm_core, :key_resolver, {MyApp.Secrets, :fetch, []}

  The resolver is called as `apply(module, function, [name | extra_args])` and must return the value as a
  string, or `nil` when it has none. It is called at use time, every time, and nothing is cached here, so a
  credential the host rotates is used from the next call on.

  It is also called **while llm_core itself starts**: the configuration loader checks each provider's
  credential when the application boots, before the host application's own processes exist. So a resolver
  must answer without depending on the host's processes. For example, it can read a boot-time seed that the
  host writes during configuration, before any of its own GenServer or ETS table is running.

  Every place in llm_core that reads a credential by name goes through `lookup/1`: the native provider
  router and the configuration loader's presence check, the OpenAI and Anthropic modules, and the Hindsight
  memory client (its configuration, its write buffer and the asynchronous retain pipeline).

  `${VAR}` interpolation in configuration files does **not** use the resolver. It keeps reading the OS
  environment, so a configured resolver never causes a credential value to be copied into the loaded
  configuration.
  """

  @default {System, :get_env, []}

  @doc """
  The value of the credential named `name`, or `nil`.

  A blank name returns `nil` without calling the resolver. A resolver that returns anything other than a
  binary is treated as returning `nil`.
  """
  @spec lookup(String.t() | nil) :: String.t() | nil
  def lookup(name) when name in [nil, ""], do: nil

  def lookup(name) when is_binary(name) do
    {module, function, extra} = resolver()

    case apply(module, function, [name | extra]) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  @doc "The configured resolver as `{module, function, extra_args}`; `{System, :get_env, []}` by default."
  @spec resolver() :: {module(), atom(), list()}
  def resolver do
    case Application.get_env(:llm_core, :key_resolver, @default) do
      {module, function, extra} = mfa
      when is_atom(module) and is_atom(function) and is_list(extra) ->
        mfa

      other ->
        raise ArgumentError,
              "config :llm_core, :key_resolver must be {module, function, extra_args}, got: " <>
                inspect(other)
    end
  end
end
