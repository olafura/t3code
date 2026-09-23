defmodule T3.MixProject do
  use Mix.Project

  def project do
    [
      app: :t3,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {T3.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:exile, "~> 0.15"},
      {:exqlite, "~> 0.41"},
      {:libcluster, "~> 3.5"},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.6"},
      {:x509, "~> 0.9"}
    ]
  end
end
