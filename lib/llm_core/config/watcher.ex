defmodule LlmCore.Config.Watcher do
  @moduledoc """
  Watches configuration directories for changes and triggers reloads.
  """

  use GenServer
  require Logger

  alias LlmCore.Config.Loader

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    dir = opts |> Keyword.get(:config_dir, LlmCore.Paths.project_config_dir()) |> Path.expand()
    debounce_ms = Keyword.get(opts, :debounce_ms, 100)
    watch_files = Keyword.get(opts, :files, ["routing.yml", "llm_core.toml"])

    File.mkdir_p!(dir)
    {:ok, watcher} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(watcher)

    {:ok,
     %{
       config_dir: dir,
       debounce_ms: debounce_ms,
       files: MapSet.new(Enum.map(watch_files, &Path.expand(&1, dir))),
       pending: MapSet.new(),
       timer: nil
     }}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) when is_binary(path) do
    state =
      if relevant?(state, path) do
        Logger.debug("llm_core config change detected at #{path}")
        state |> queue(path) |> schedule_flush()
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:flush, state) do
    Enum.each(state.pending, &reload_path/1)
    {:noreply, %{state | pending: MapSet.new(), timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp relevant?(state, path) do
    normalized = Path.expand(path)

    MapSet.member?(state.files, normalized) ||
      Enum.any?(state.files, fn file -> String.starts_with?(normalized, file) end)
  end

  defp queue(state, path) do
    %{state | pending: MapSet.put(state.pending, Path.expand(path))}
  end

  defp schedule_flush(%{timer: nil} = state) do
    ref = Process.send_after(self(), :flush, state.debounce_ms)
    %{state | timer: ref}
  end

  defp schedule_flush(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    schedule_flush(%{state | timer: nil})
  end

  defp reload_path(path) do
    cond do
      String.ends_with?(path, "routing.yml") -> Loader.reload_routing(path: path)
      String.ends_with?(path, "llm_core.toml") -> Loader.reload_providers(path: path)
      true -> :ok
    end
  end
end
