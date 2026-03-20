defmodule Crown.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/lud/crown"

  def project do
    [
      app: :crown,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description: "A leader election and supervisor library for Elixir, using external oracles",
      package: package(),
      source_url: @source_url,
      dialyzer: dialyzer(),
      docs: [main: "Crown"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        dialyzer: :test
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Crown.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_options, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:local_cluster, "~> 2.0", only: :test},

      # Oracles dependencies
      {:ecto_sql, ">= 3.0.0", optional: true},
      {:ecto, ">= 3.0.0", optional: true},
      {:postgrex, ">= 0.0.0", only: :test},

      # Dev
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_check, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:readmix, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:quokka, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  defp dialyzer do
    [
      flags: [:unmatched_returns, :error_handling, :unknown, :extra_return],
      list_unused_filters: true,
      plt_add_deps: :app_tree,
      plt_local_path: "_build/plts"
    ]
  end
end
