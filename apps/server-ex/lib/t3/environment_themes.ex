defmodule T3.EnvironmentThemes do
  @moduledoc """
  Palettes this machine publishes for clients to follow, as the Node server's
  EnvironmentThemeService does: a desktop that retints its apps writes
  `<home>/themes/<id>.json`, and every client watching this node's config gets
  the whole set when it changes (`{:t3_themes, node, themes}` through
  `T3.Settings` watchers). The filename is the theme's id.

  Theming is cosmetic, so a file that is missing, too big, a symlink, malformed or
  colorless is skipped, never an error. The directory is checked every couple of
  seconds; a check reads only file sizes and times unless something changed.
  """

  use GenServer

  @max_files 32
  @max_file_bytes 32 * 1024
  @max_total_bytes 192 * 1024
  @id ~r/^(?!(?:system|light|dark)$)[a-z0-9](?:[a-z0-9-]{0,47})$/
  @reserved ~w(system light dark t3-chat grove ocean ember iris t3-chat-dark t3-grove t3-ocean
               t3-ember t3-iris t3-code)
  @color ~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/
  @role ~r/^[a-zA-Z][a-zA-Z0-9]{0,63}$/

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The published set right now."
  def current do
    GenServer.call(__MODULE__, :current)
  catch
    :exit, {:noproc, _} -> []
  end

  @impl true
  def init(nil) do
    File.mkdir_p(dir())
    schedule()
    {:ok, %{stamp: stamp(), themes: read()}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.themes, state}

  @impl true
  def handle_info(:check, state) do
    schedule()
    stamp = stamp()

    if stamp == state.stamp do
      {:noreply, state}
    else
      themes = read()
      if themes != state.themes, do: T3.Settings.notify_themes(themes)
      {:noreply, %{state | stamp: stamp, themes: themes}}
    end
  end

  defp schedule do
    case Application.get_env(:t3, :theme_check_ms, 2_000) do
      nil -> :ok
      ms -> Process.send_after(self(), :check, ms)
    end
  end

  defp dir, do: Path.join(Application.fetch_env!(:t3, :home), "themes")

  # What a change would show in: names, sizes and modification times.
  defp stamp do
    case File.ls(dir()) do
      {:ok, names} ->
        for name <- Enum.sort(names), String.ends_with?(name, ".json") do
          case File.lstat(Path.join(dir(), name), time: :posix) do
            {:ok, stat} -> {name, stat.size, stat.mtime, stat.type}
            _ -> {name, nil}
          end
        end

      _ ->
        []
    end
  end

  @doc false
  def read do
    names =
      case File.ls(dir()) do
        {:ok, names} -> Enum.sort(names)
        _ -> []
      end

    names
    |> Enum.flat_map(fn name ->
      id = String.replace_suffix(name, ".json", "")

      if String.ends_with?(name, ".json") and Regex.match?(@id, id) and id not in @reserved,
        do: [{id, Path.join(dir(), name)}],
        else: []
    end)
    # Files examined, not themes accepted, are capped, so a directory of bad
    # files is not read in full on every change.
    |> Enum.take(@max_files)
    |> Enum.reduce_while({[], 0}, fn {id, path}, {themes, total} ->
      with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
             File.lstat(path),
           {:ok, raw} <- File.read(path),
           {:ok, %{} = file} <- JSON.decode(raw),
           %{} = theme <- theme(id, file) do
        total = total + byte_size(raw)

        if total > @max_total_bytes,
          do: {:halt, {themes, total}},
          else: {:cont, {[theme | themes], total}}
      else
        _ -> {:cont, {themes, total}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # The file's own `id` is ignored: the filename is the identity.
  defp theme(id, file) do
    name = file["name"]
    colors = file["colors"]

    valid =
      file["version"] in [nil, 1] and is_binary(name) and String.trim(name) != "" and
        String.length(name) <= 48 and file["appearance"] in ["light", "dark"] and
        Enum.all?([file["canvas"], file["accent"]], &(&1 == nil or color?(&1))) and
        palette?(colors) and variants?(file["variants"]) and
        ((file["canvas"] != nil and file["accent"] != nil) or (is_map(colors) and colors != %{}))

    if valid do
      file
      |> Map.take(~w(version name appearance canvas accent colors variants))
      |> Map.put("id", id)
    end
  end

  defp color?(value), do: is_binary(value) and Regex.match?(@color, value)

  defp palette?(nil), do: true

  defp palette?(%{} = colors) do
    Enum.all?(colors, fn {role, value} ->
      Regex.match?(@role, role) and is_binary(value) and String.trim(value) != "" and
        String.length(value) <= 64
    end)
  end

  defp palette?(_), do: false

  defp variants?(nil), do: true

  defp variants?(%{} = variants),
    do: palette?(variants["light"]) and palette?(variants["dark"])

  defp variants?(_), do: false
end
