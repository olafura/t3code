defmodule T3.Cluster do
  @moduledoc """
  Trust and transport for a cluster of one person's machines.

  Nodes talk over Erlang distribution wrapped in mutual TLS 1.3. Trust comes from a
  cluster CA, not the cookie: a node connects only if its certificate was signed by
  the same CA, so a machine joins once (`invite/2` on a member, `join/1` on the new
  machine) and discovery can then try any peer it finds.

  Files live in `<home>/cluster/`:

    * `ca.pem` - the cluster CA certificate (every member)
    * `ca.key` - the CA key (only on members that can invite)
    * `node.pem`, `node.key` - this machine's certificate and key
    * `ssl_dist.conf` - the distribution TLS options, read by the VM at boot
    * `vm.args` - the flags from `vm_args/1`, which a release boots with

  Distribution runs without EPMD on `@dist_port`, one node per machine, named
  `t3@<address>`. See `vm_args/1` for the flags a node must boot with. The cookie is
  derived from the CA certificate so members share it without extra setup; it is not
  a secret, since the TLS handshake is what admits a node.
  """

  @dist_port 4370
  @valid_days 3650

  def dist_port, do: @dist_port

  @spec dir(String.t()) :: String.t()
  def dir(home), do: Path.join(home, "cluster")

  @doc "Creates a new cluster CA and a certificate for this machine at `address`."
  @spec init(String.t(), String.t()) :: :ok | {:error, :already_initialized}
  def init(home, address) do
    dir = dir(home)

    if File.exists?(Path.join(dir, "ca.pem")) do
      {:error, :already_initialized}
    else
      File.mkdir_p!(dir)
      ca_key = X509.PrivateKey.new_ec(:secp256r1)

      ca =
        X509.Certificate.self_signed(ca_key, "/CN=T3 cluster #{random_id()}",
          template: :root_ca,
          validity: @valid_days
        )

      write(dir, "ca.pem", X509.Certificate.to_pem(ca))
      write(dir, "ca.key", X509.PrivateKey.to_pem(ca_key), 0o600)
      install_bundle(home, issue(ca, ca_key, address))
    end
  end

  @doc """
  Issues a join bundle for a machine reachable at `address` (an IP or DNS name). The
  bundle holds that machine's key, so hand it over privately and only once.
  """
  @spec invite(String.t(), String.t()) :: binary
  def invite(home, address) do
    dir = dir(home)
    ca = dir |> Path.join("ca.pem") |> File.read!() |> X509.Certificate.from_pem!()
    ca_key = dir |> Path.join("ca.key") |> File.read!() |> X509.PrivateKey.from_pem!()
    :erlang.term_to_binary(issue(ca, ca_key, address))
  end

  @doc "Installs a bundle from `invite/2` on this machine."
  @spec join(String.t(), binary) :: :ok
  def join(home, bundle), do: install_bundle(home, :erlang.binary_to_term(bundle, [:safe]))

  @doc "The address this machine's certificate was issued for, if it has joined."
  @spec address(String.t()) :: String.t() | nil
  def address(home) do
    case File.read(Path.join(dir(home), "address")) do
      {:ok, address} -> String.trim(address)
      {:error, _} -> nil
    end
  end

  @doc """
  VM flags for a clustered node: TLS distribution, no EPMD, the fixed port, and the
  node name. Returns `nil` until the machine has a certificate.
  """
  @spec vm_args(String.t()) :: String.t() | nil
  def vm_args(home) do
    if address = address(home) do
      Enum.join(
        [
          "-name t3@#{address}",
          "-setcookie #{cookie(home)}",
          "-proto_dist inet_tls",
          "-ssl_dist_optfile #{Path.join(dir(home), "ssl_dist.conf")}",
          "-start_epmd false",
          "-erl_epmd_port #{@dist_port}",
          "-kernel inet_dist_listen_min #{@dist_port} inet_dist_listen_max #{@dist_port}"
        ] ++ listen_interface(address),
        " "
      )
    end
  end

  # Listen only on the cluster address (the tailnet IP), not every interface.
  defp listen_interface(address) do
    case :inet.parse_ipv4_address(to_charlist(address)) do
      {:ok, {a, b, c, d}} -> ["-kernel inet_dist_use_interface {#{a},#{b},#{c},#{d}}"]
      {:error, _} -> []
    end
  end

  defp cookie(home) do
    ca = File.read!(Path.join(dir(home), "ca.pem"))
    Base.encode32(:crypto.hash(:sha256, ca), padding: false, case: :lower)
  end

  defp issue(ca, ca_key, address) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    san =
      case :inet.parse_address(to_charlist(address)) do
        {:ok, ip} -> {:iPAddress, ip |> Tuple.to_list() |> :binary.list_to_bin()}
        {:error, _} -> {:dNSName, to_charlist(address)}
      end

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=t3@#{address}", ca, ca_key,
        template: :server,
        validity: @valid_days,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([san])]
      )

    %{
      address: address,
      ca: X509.Certificate.to_pem(ca),
      cert: X509.Certificate.to_pem(cert),
      key: X509.PrivateKey.to_pem(key)
    }
  end

  defp install_bundle(home, %{address: address, ca: ca, cert: cert, key: key}) do
    dir = dir(home)
    File.mkdir_p!(dir)
    write(dir, "ca.pem", ca)
    write(dir, "node.pem", cert)
    write(dir, "node.key", key, 0o600)
    write(dir, "address", address)
    write(dir, "ssl_dist.conf", ssl_dist_conf(dir))
    # Read by the release at boot (rel/env.sh.eex) to start clustered.
    write(dir, "vm.args", String.replace(vm_args(home), " -", "\n-") <> "\n")
  end

  # file:consult/1 format: plain terms only, no function calls.
  defp ssl_dist_conf(dir) do
    opts = fn extra ->
      [
        certfile: to_charlist(Path.join(dir, "node.pem")),
        keyfile: to_charlist(Path.join(dir, "node.key")),
        cacertfile: to_charlist(Path.join(dir, "ca.pem")),
        verify: :verify_peer,
        versions: [:"tlsv1.3"]
      ] ++ extra
    end

    conf = [server: opts.(fail_if_no_peer_cert: true), client: opts.([])]
    :io_lib.format(~c"~p.~n", [conf]) |> IO.iodata_to_binary()
  end

  defp write(dir, name, contents, mode \\ 0o644) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    File.chmod!(path, mode)
  end

  defp random_id, do: Base.encode32(:crypto.strong_rand_bytes(5), padding: false)
end
