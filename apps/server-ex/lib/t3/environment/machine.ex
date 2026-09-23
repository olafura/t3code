defmodule T3.Environment.Machine do
  @moduledoc """
  The host's hardware shape for the environment icon (`platform.machine`), as the
  Node server detects it: Apple product names on macOS, DMI on Linux. Every probe
  may fail; `nil` means no signal, and clients draw a generic server until the
  user picks an icon. Detected once per node.
  """

  # SMBIOS System Enclosure types; shapes that are not machines fall through.
  @chassis %{
    "3" => "desktop",
    "4" => "desktop",
    "5" => "desktop",
    "6" => "desktop",
    "7" => "desktop",
    "8" => "laptop",
    "9" => "laptop",
    "10" => "laptop",
    "13" => "desktop",
    "14" => "laptop",
    "15" => "desktop",
    "16" => "desktop",
    "17" => "server",
    "18" => "server",
    "19" => "server",
    "20" => "server",
    "21" => "server",
    "22" => "server",
    "23" => "server",
    "24" => "server",
    "28" => "server",
    "31" => "laptop",
    "32" => "laptop",
    "35" => "desktop"
  }
  # Hypervisors and clouds name themselves in the DMI vendor or product; a VM is "cloud".
  @virtual ~w(qemu kvm bochs vmware virtualbox innotek xen parallels digitalocean hetzner
              linode vultr scaleway openstack cloud) ++
             ["amazon ec2", "google compute engine", "virtual machine"]

  def kind do
    case :persistent_term.get(__MODULE__, :unknown) do
      :unknown ->
        kind = detect()
        :persistent_term.put(__MODULE__, kind)
        kind

      kind ->
        kind
    end
  end

  defp detect do
    case :os.type() do
      {:unix, :darwin} -> darwin()
      {:unix, :linux} -> linux()
      _ -> nil
    end
  end

  # Apple silicon names the product in IOKit; Intel Macs only have `hw.model`.
  defp darwin do
    product =
      with text when is_binary(text) <- probe("ioreg", ["-rd1", "-n", "product"]),
           [_, name] <- Regex.run(~r/"product-name"\s*=\s*<"([^"]+)">/, text) do
        apple(name)
      else
        _ -> nil
      end

    product ||
      case probe("sysctl", ["-n", "hw.model"]) do
        nil -> nil
        model -> apple(model)
      end
  end

  defp linux do
    # WSL is Microsoft's kernel on a Hyper-V VM; it reads as Linux.
    if String.contains?(String.downcase(read("/proc/sys/kernel/osrelease") || ""), "microsoft") do
      "linux"
    else
      from_dmi(
        read("/sys/class/dmi/id/chassis_type"),
        read("/sys/class/dmi/id/sys_vendor"),
        read("/sys/class/dmi/id/product_name")
      )
    end
  end

  @doc false
  def from_dmi(chassis, vendor, product) do
    both = String.downcase("#{vendor} #{product}")

    cond do
      Enum.any?(@virtual, &String.contains?(both, &1)) -> "cloud"
      kind = apple(product || "") -> kind
      true -> @chassis[chassis]
    end
  end

  @doc false
  def apple(name) do
    name = name |> String.downcase() |> String.replace(~r/\s+/, "")

    cond do
      String.starts_with?(name, "macmini") -> "mac-mini"
      String.starts_with?(name, "macstudio") -> "mac-studio"
      String.starts_with?(name, "macbook") -> "laptop"
      String.starts_with?(name, ["imac", "macpro"]) -> "desktop"
      true -> nil
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> present(text)
      _ -> nil
    end
  end

  defp probe(command, args) do
    with path when is_binary(path) <- System.find_executable(command),
         {text, 0} <- System.cmd(path, args) do
      present(text)
    else
      _ -> nil
    end
  end

  defp present(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
