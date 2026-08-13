defmodule ReactiveDagDashboard.Observer do
  @moduledoc """
  Turns the engine's telemetry into LiveView messages.

  The drain emits `:telemetry` events (`reactive_dag` v0.17+); LiveViews need
  process messages. This is the bridge: one `:telemetry` handler per node,
  broadcasting over `Phoenix.PubSub` so any number of open dashboards hear the
  same drain.

  ## Why a bridge and not a direct subscribe

  A telemetry handler runs **inside the drain's own process**. Doing anything
  slow there — a query, a render — puts dashboard latency on the critical path
  of the engine, which is exactly backwards. So the handler does the least
  possible work: copy a few fields into a message and hand it to PubSub. Every
  read happens later, in the LiveView's process, where it can be slow without
  costing the drain anything.

  ## What is broadcast

      {:drain_step, cell_id, changed_keys}   after each cell recomputes
      {:drain_done, report}                  when the drain finishes
      {:drain_failed, reason}                when it raised

  `:drain_step` names the cell and its changed keys, which is what lets a view
  refresh **only that cell** rather than re-reading the graph. That distinction
  is the whole reason to be told at all: a notification that means "something,
  somewhere, changed" costs the same full re-read that polling did.

  ## Attaching

      # in the host's application start
      ReactiveDagDashboard.Observer.attach(MyApp.PubSub)

  Idempotent — attaching twice is a no-op rather than an error, so a supervisor
  restart does not crash the app. If it is never called, the dashboard falls
  back to its poll interval and still works; it just is not live.
  """

  require Logger

  @handler "reactive-dag-dashboard-observer"
  @topic "reactive_dag:drain"

  @events [
    [:reactive_dag, :drain, :step],
    [:reactive_dag, :drain, :stop],
    [:reactive_dag, :drain, :exception]
  ]

  @doc "The PubSub topic drain events are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Attach the telemetry handler, broadcasting over `pubsub`.

  Returns `:ok` whether or not it was already attached.
  """
  @spec attach(module()) :: :ok
  def attach(pubsub) when is_atom(pubsub) do
    case :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, %{pubsub: pubsub}) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        :ok
    end
  end

  @doc "Detach the handler. For tests, and for a host that wants to stop observing."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler)
    :ok
  end

  @doc "Whether the handler is currently attached — what the UI reads to say 'live'."
  @spec attached?() :: boolean()
  def attached? do
    Enum.any?(:telemetry.list_handlers([:reactive_dag, :drain, :stop]), &(&1.id == @handler))
  end

  @doc false
  # Runs in the DRAIN's process. Keep it trivial: no queries, no rendering, and
  # never let a broadcast failure propagate — a dashboard that cannot be reached
  # must not fail the drain that was only informing it.
  def handle([:reactive_dag, :drain, :step], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:drain_step, metadata.cell, metadata.changed_keys})
  end

  def handle([:reactive_dag, :drain, :stop], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:drain_done, metadata.report})
  end

  def handle([:reactive_dag, :drain, :exception], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:drain_failed, metadata.reason})
  end

  defp broadcast(pubsub, message) do
    Phoenix.PubSub.broadcast(pubsub, @topic, message)
    :ok
  rescue
    error ->
      Logger.warning(
        "reactive_dag_dashboard: could not broadcast #{inspect(elem(message, 0))} — " <>
          Exception.message(error)
      )

      :ok
  end
end
