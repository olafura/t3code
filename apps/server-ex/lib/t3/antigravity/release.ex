defmodule T3.Antigravity.Release do
  @moduledoc """
  The official Google Antigravity ACP runtime this node installs
  (`T3.Antigravity.Installation`), pinned per platform: its URL, the archive's
  SHA-256 and size, and the two files the archive holds with their sizes.

  URLs come from the ACP Registry's antigravity-acp entry; the hashes and sizes were
  checked on 2026-09-03 (the Node server pins the same release). The
  `:antigravity_release` app env replaces the table's entry for this machine (a local
  mirror, tests); `false` there means no release for it.
  """

  @version "agy_acp_server_1.1.1"

  @assets %{
    "darwin-arm64" => %{
      url:
        "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_1.1.1-darwin-arm64.zip",
      sha256: "fdfa915652cdb7ba8085cc8fffed072cbe009251aa2c951aabdda07a8c28a189",
      archive_bytes: 316_014_828,
      executable: {"agy_acp_server.par", 802_163_856},
      harness: {"localharness_external", 116_766_704}
    },
    "linux-x64" => %{
      url:
        "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-agy_acp_server_1.1.1-linux-x86_64.zip",
      sha256: "38f62d01b32deb0907b3d39a71ec301fd36369f6ffd1cf262d4af385177f79df",
      archive_bytes: 681_969_407,
      executable: {"agy_acp_server.par", 1_880_360_328},
      harness: {"localharness_external", 128_966_920}
    },
    "linux-arm64" => %{
      url:
        "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-agy_acp_server_1.1.1-linux-arm64.zip",
      sha256: "ed69e64b308fcb123ab54bf3277bf9cb0d651064f885ea5aab0ff520c7175398",
      archive_bytes: 656_572_786,
      executable: {"agy_acp_server.par", 1_862_073_131},
      harness: {"localharness_external", 122_158_704}
    },
    "win32-x64" => %{
      url:
        "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-agy_acp_server_1.1.1-windows-x86_64.zip",
      sha256: "47cb50eef14f0a4655d78cfcfda869bcea7aaee5f9787e936bc2935ea612c3b8",
      archive_bytes: 468_238_392,
      executable: {"agy_acp_server.exe", 430_801_616},
      harness: {"localharness_external.exe", 130_971_800}
    },
    "win32-arm64" => %{
      url:
        "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-agy_acp_server_1.1.1-windows-arm64.zip",
      sha256: "35f4b1f47ba6a3fea7b0a3e30010df5ea73a64b4f0e7cf991cddc673ddfbcafc",
      archive_bytes: 468_521_191,
      executable: {"agy_acp_server.exe", 435_075_816},
      harness: {"localharness_external.exe", 122_455_704}
    }
  }

  @type asset :: %{
          version: String.t(),
          url: String.t(),
          sha256: String.t(),
          archive_bytes: pos_integer,
          executable: {String.t(), pos_integer},
          harness: {String.t(), pos_integer}
        }

  @doc "The release for this machine, or `nil` where Google publishes none."
  @spec asset() :: asset | nil
  def asset do
    case Application.get_env(:t3, :antigravity_release) do
      nil -> asset(platform())
      false -> nil
      %{} = asset -> Map.put_new(asset, :version, @version)
    end
  end

  @doc "The release for a platform key such as `darwin-arm64`, or `nil`."
  def asset(platform) do
    case @assets[platform] do
      nil -> nil
      asset -> Map.put(asset, :version, @version)
    end
  end

  @doc "The runtime's two file names on this OS: `{executable, harness}`."
  def names do
    if match?({:win32, _}, :os.type()),
      do: {"agy_acp_server.exe", "localharness_external.exe"},
      else: {"agy_acp_server.par", "localharness_external"}
  end

  @doc "This machine as Node names it: `darwin-arm64`, `linux-x64`, …"
  def platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "win32"
        {_, other} -> Atom.to_string(other)
      end

    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    arch =
      cond do
        arch =~ ~r/aarch64|arm64/ -> "arm64"
        arch =~ ~r/x86_64|amd64/ -> "x64"
        true -> arch
      end

    "#{os}-#{arch}"
  end
end
