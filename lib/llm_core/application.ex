defmodule LlmCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LlmCore.Config.Store,
        {LlmCore.Agent.Registry, []},
        LlmCore.Router
      ]
      |> maybe_add_watcher()
      |> maybe_add_hindsight()

    case Supervisor.start_link(children, strategy: :one_for_one, name: LlmCore.Supervisor) do
      {:ok, _pid} = ok ->
        _ = LlmCore.Config.Loader.reload_providers()
        _ = LlmCore.Config.Loader.reload_routing()
        ok

      other ->
        other
    end
  end

  defp maybe_add_watcher(children) do
    if Application.get_env(:llm_core, :enable_config_watcher, true) do
      config_dir = Application.get_env(:llm_core, :config_dir, LlmCore.Paths.project_config_dir())
      children ++ [{LlmCore.Config.Watcher, [config_dir: config_dir]}]
    else
      children
    end
  end

  defp maybe_add_hindsight(children) do
    if Application.get_env(:llm_core, :enable_hindsight, true) do
      children ++ [LlmCore.Memory.Hindsight.Supervisor]
    else
      children
    end
  end
end
