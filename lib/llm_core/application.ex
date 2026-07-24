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

    case Supervisor.start_link(children, strategy: :one_for_one, name: LlmCore.Supervisor) do
      {:ok, supervisor} = ok ->
        with {:ok, _providers} <- LlmCore.Config.Loader.reload_providers(),
             {:ok, _routing} <- LlmCore.Config.Loader.reload_routing(),
             :ok <- maybe_start_memory(supervisor) do
          ok
        else
          {:error, reason} ->
            Supervisor.stop(supervisor)
            {:error, reason}
        end

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

  defp maybe_start_memory(supervisor) do
    enabled =
      Application.get_env(
        :llm_core,
        :enable_memory,
        Application.get_env(:llm_core, :enable_hindsight, true)
      )

    if enabled do
      case Supervisor.start_child(supervisor, LlmCore.Memory.Hindsight.Supervisor) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
