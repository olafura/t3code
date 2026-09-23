defmodule T3.Codex.Provider do
  @moduledoc """
  The Codex entry in this node's `ServerConfig.providers`, which is what lets a
  client's composer send to Codex here.

  The entry appears when the `codex` command is on the node's PATH. Its model list
  comes from `codex app-server`'s `model/list`, read once in the background at boot
  (`load/0`); until then a single default model is offered.
  """

  alias T3.JsonRpc.Connection

  @key {__MODULE__, :models}
  @default_models [%{"slug" => "gpt-5.5", "name" => "GPT-5.5", "isDefault" => true}]

  @doc "The provider entry, or nil when Codex is not installed on this node."
  @spec entry() :: map | nil
  def entry do
    with [executable | _] <- command(),
         path when is_binary(path) <- System.find_executable(executable) do
      %{
        "instanceId" => "codex",
        "driver" => "codex",
        "enabled" => true,
        "installed" => true,
        "version" => version(path),
        "versionAdvisory" => T3.ProviderUpdates.advisory("codex", path, version(path)),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => T3.Orchestration.Entities.now(),
        "models" =>
          for(model <- :persistent_term.get(@key, @default_models), do: model_entry(model)),
        "slashCommands" => [],
        "skills" => []
      }
    else
      _ -> nil
    end
  end

  @doc "Reads the model list from `codex app-server`; run once at boot."
  def load do
    with [_ | _] = cmd <- command(),
         {:ok, conn} <- Connection.start_link(cmd: cmd, handler: self()),
         {:ok, _} <-
           Connection.call(conn, "initialize", %{
             "clientInfo" => %{"name" => "t3code_elixir", "version" => "0.1.0"}
           }),
         :ok <- Connection.notify(conn, "initialized", nil),
         {:ok, %{"data" => [_ | _] = models}} <- Connection.call(conn, "model/list", %{}) do
      :persistent_term.put(
        @key,
        for(
          m <- models,
          do: %{
            "slug" => m["model"] || m["id"],
            "name" => m["displayName"] || m["model"] || m["id"],
            "isDefault" => m["isDefault"] == true
          }
        )
      )

      Connection.stop(conn)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp model_entry(model),
    do: %{
      "slug" => model["slug"],
      "name" => model["name"],
      "isCustom" => false,
      "isDefault" => model["isDefault"] == true,
      "capabilities" => nil
    }

  defp command, do: Application.get_env(:t3, :codex_command, ["codex", "app-server"])

  defp version(path) do
    case :persistent_term.get({__MODULE__, :version}, nil) do
      nil ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.last() |> Kernel.||("unknown")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, version)
        version

      version ->
        version
    end
  rescue
    _ -> "unknown"
  end
end
