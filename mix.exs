defmodule ReactiveDagDashboard.MixProject do
  use Mix.Project

  @moduledoc false

  # release-please manages this version (and the tag/CHANGELOG) via the
  # annotation below — bump it by merging the release PR, not by hand.
  @version "0.1.0" # x-release-please-version

  def project do
    [
      app: :reactive_dag_dashboard,
      version: @version,
      elixir: "~> 1.18",
      description:
        "Graph status dashboard for reactive_dag: the DAG's structure, per-cell " <>
          "status, and the drain trace, as a Phoenix LiveView you mount inside " <>
          "your own auth pipeline.",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/u2i/reactive_dag_dashboard",
        "reactive_dag" => "https://github.com/u2i/reactive_dag"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/u2i/reactive_dag_dashboard",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp deps do
    [
      # git until 0.17 is on hex (release-please u2i/reactive_dag#25). Tracks
      # main, where the 0.17 release candidates land — `mix deps.update
      # reactive_dag` moves to the newest rc, and mix.lock pins the exact SHA in
      # between so a breaking change never arrives unannounced. 0.17 removed the
      # coordination tuple and the tableless verdict node; the tests below are
      # what catch the next one.
      {:reactive_dag, github: "u2i/reactive_dag", branch: "main"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
