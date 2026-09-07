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
          "status, and the cascade trace, as a Phoenix LiveView you mount inside " <>
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
      # ONE floor: rc.59, the release that replaced the drain with a cascade.
      #
      # The long list of rc floors that used to sit here — each naming the
      # release that added a field this page reads — is gone with the engine
      # those releases built. `ReactiveDag.Drain` and `ReactiveDag.Frontier` no
      # longer exist, the telemetry root moved from `[:reactive_dag, :drain, *]`
      # to `[:reactive_dag, :cascade, *]`, and `Drain.Report` became
      # `ReactiveDag.Report`.
      #
      # Everything else this page needs shipped before rc.59, and a dashboard
      # built for the drain cannot PARTIALLY work against a cascade — it hears
      # no events at all — so one floor says everything a list of them would.
      # rc.69 FLOOR: `ReactiveDag.Run` — the persistent run log this page reads
      # for history and for outstanding work. Below it the module is absent and
      # `runs/1` falls back to the ETS buffer alone, which is the behaviour this
      # page had before; but `outstanding` would be permanently empty while
      # claiming to show what is queued, so the floor is real rather than a
      # preference.
      {:reactive_dag, "~> 0.17.0-rc.69", override: true},
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
