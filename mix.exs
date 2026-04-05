defmodule UptrackWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :uptrack_worker,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {UptrackWorker.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gun, "~> 2.1"},
      {:mint, "~> 1.6"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:libcluster, "~> 3.4"}
    ]
  end
end
