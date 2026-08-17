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
      # A RANGE over the rc series, not an exact pin. `~>` on a pre-release does
      # resolve later pre-releases (Mix passes `allow_pre` for deps), so this
      # accepts rc.19+, the 0.17.0 final and its patches, while holding 0.18 for
      # a deliberate bump — 0.17 removed the coordination tuple, the tableless
      # verdict node and the :on_step callback, and a major bump deserves the
      # same scrutiny.
      #
      # It was `== 0.17.0-rc.N` on the belief that `~>` could not match a
      # pre-release at all. That is not so, and the exact pin meant a PR here per
      # library release even when nothing in this dashboard cared.
      {:reactive_dag, "~> 0.17.0-rc.26"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      # Optional, and only for the scan button: with Oban the page queues a scan
      # (a crawl can take minutes, and blocking the LiveView would look hung);
      # without it, the scan runs inline. A host running this dashboard purely
      # for display needs neither.
      {:oban, "~> 2.17", optional: true},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
