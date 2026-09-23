defmodule T3.Claude.Provider do
  @moduledoc """
  The Claude entry in this node's `ServerConfig.providers`, present when the `claude`
  CLI is on the node's PATH. Models are the CLI's aliases, which it resolves to the
  current model of each family.
  """

  @models [
    %{"slug" => "sonnet", "name" => "Claude Sonnet", "isDefault" => true},
    %{"slug" => "opus", "name" => "Claude Opus", "isDefault" => false},
    %{"slug" => "haiku", "name" => "Claude Haiku", "isDefault" => false}
  ]

  @spec entry() :: map | nil
  def entry do
    with [executable | _] <- Application.get_env(:t3, :claude_command, ["claude"]),
         path when is_binary(path) <- System.find_executable(executable) do
      %{
        "instanceId" => "claudeAgent",
        "driver" => "claudeAgent",
        "enabled" => true,
        "installed" => true,
        "version" => version(path),
        "versionAdvisory" => T3.ProviderUpdates.advisory("claudeAgent", path, version(path)),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => T3.Orchestration.Entities.now(),
        "models" =>
          for(
            m <- @models,
            do: Map.merge(m, %{"isCustom" => false, "capabilities" => nil})
          ),
        "slashCommands" => [],
        "skills" => []
      }
    else
      _ -> nil
    end
  end

  defp version(path) do
    case :persistent_term.get({__MODULE__, :version}, nil) do
      nil ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.first() |> Kernel.||("unknown")
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
