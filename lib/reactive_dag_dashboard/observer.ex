defmodule ReactiveDagDashboard.Observer do
  @moduledoc """
  Turns the engine's telemetry into LiveView messages.

  The cascade emits `:telemetry` events under `[:reactive_dag, :cascade, *]`;
  LiveViews need process messages. This is the bridge: one `:telemetry` handler
  per node, broadcasting over `Phoenix.PubSub` so any number of open dashboards
  hear the same cascade.

  ## Why a bridge and not a direct subscribe

  A telemetry handler runs **inside the cascade's own process** — and a cascade
  runs in a transaction, so that process is holding a database connection while
  this code executes. Doing anything slow there — a query, a render — puts
  dashboard latency on the critical path of the engine, which is exactly
  backwards. So the handler does the least possible work: copy a few fields into
  a message and hand it to PubSub. Every read happens later, in the LiveView's
  process, where it can be slow without costing the cascade anything.

  ## What is broadcast

      {:cell_running, cell_id, claimed}      a cell BEGAN recomputing
      {:cell_progress, cell_id, done, total, label} a recompute advanced
      {:cascade_step, cell_id, changed_keys} after each cell recomputes
      {:cascade_done, report}                when the cascade finishes
      {:cascade_failed, reason}              when it raised
      {:cell_failed, cell_id, reason}        one cell failed; the cascade went on
      {:suspended, cell_id, waiting, reason, count}    the cascade STOPPED here
      {:resumed, cell_id, waiting, suspensions}        a job picked that point up
      {:resumption_done, cell_id, waiting, discharged} and cleared it
      {:scan_started, cell_id}               a poll began
      {:scan_progress, cell_id, done, total, label} a poll advanced
      {:scan_done, cell_id, result}          a poll finished, changed or not
      {:scan_failed, cell_id, reason}        it raised

  `:scan_done` carries a `ReactiveDag.ScanRun`, because a scan that changed
  NOTHING is a real outcome and the page has to be able to say so.

  A poll no longer propagates in its own job, though: it ENQUEUES a cascade per
  changed leaf and returns. So `run.report` is always nil, and the recompute
  arrives SEPARATELY as `:cascade_*` messages from whichever job ran it — the
  page can no longer treat a scan's completion as the end of the work it caused.

  `:cascade_step` names the cell and its changed keys, which is what lets a view
  refresh **only that cell** rather than re-reading the graph. That distinction
  is the whole reason to be told at all: a notification that means "something,
  somewhere, changed" costs the same full re-read that polling did.

  ## The three suspension events

  These have no counterpart under the old engine, and they are the ones worth
  watching. A cascade is a single walk that runs until it reaches work it cannot
  do inline — too expensive to hold a transaction open for, or needing a person
  — and then STOPS.

  `:suspended` is that stop. It is neither a failure nor a completion, which is
  exactly why it needs a message of its own: a page told only about steps and
  stops sees a cascade that ended cleanly, with no hint that a branch of it is
  parked until something else happens. `:resumed` and `:resumption_done` are the
  other half — a job picking that point back up, and clearing it. A `:suspended`
  with no matching `:resumption_done` is the shape of work nobody is clearing.

  ## Attaching

      # in the host's application start
      ReactiveDagDashboard.Observer.attach(MyApp.PubSub)

  Idempotent — attaching twice is a no-op rather than an error, so a supervisor
  restart does not crash the app. If it is never called, the dashboard falls
  back to its poll interval and still works; it just is not live.
  """

  require Logger

  @handler "reactive-dag-dashboard-observer"
  # The topic keeps its name across the engine change. It is a string hosts put
  # in their own `subscribe/2` calls, so renaming it would break every such host
  # for a cosmetic gain — and the topic was never about the drain specifically,
  # only about "this library's propagation events".
  @topic "reactive_dag:drain"

  @events [
    [:reactive_dag, :cascade, :step],
    # BEFORE a cell recomputes. `:step` fires when it FINISHES, so the slowest cell
    # in a graph — an LLM extraction running for minutes — is invisible for exactly
    # as long as it is the one working. The page then holds whatever it last heard,
    # which after a poll is that poll's final phase, and a working cascade reads as
    # a hang.
    [:reactive_dag, :cascade, :cell_start],
    # From inside ONE recompute. `:cell_start` names the slow cell; this says how far
    # through it is — "meeting_events · 12/34 meetings" rather than four minutes of
    # "recomputing".
    [:reactive_dag, :cascade, :progress],
    [:reactive_dag, :cascade, :stop],
    [:reactive_dag, :cascade, :exception],
    [:reactive_dag, :cascade, :cell_failed],
    # A cell that failed WITHOUT failing the cascade. Neither a `:step` (it never
    # recomputed) nor an `:exception` (the cascade finished), so without this a
    # contained failure produces no event at all and the page shows a clean
    # cascade over a cell that silently did not run.
    #
    # WHERE THE CASCADE STOPPED. New with the cascade engine, and the events
    # that carry what nothing else does: a suspension ends a branch without
    # failing anything, so a page watching only `:step`/`:stop` sees a clean
    # finish over work that has been parked. `:resumed`/`:resumption_done` are
    # the other end — the job that picks the point back up and clears it.
    [:reactive_dag, :cascade, :suspended],
    [:reactive_dag, :cascade, :resumed],
    [:reactive_dag, :cascade, :resumption_done],
    # The SCAN half. A poll that finds nothing enqueues nothing, so it produces no
    # `:cascade, :step` at all — and a page told only about steps cannot tell a
    # scan that found nothing from a scan that never ran. Both looked like the
    # button doing nothing, which is how a working scan reads as broken.
    [:reactive_dag, :scan, :start],
    [:reactive_dag, :scan, :stop],
    [:reactive_dag, :scan, :exception],
    # From inside one poll. A crawl of 700 documents is otherwise a single
    # `:stop` that fires once it is over, so the page says "polling…" for
    # minutes and then jumps to a result.
    [:reactive_dag, :scan, :progress]
  ]

  @doc "The PubSub topic cascade and scan events are broadcast on."
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
    Enum.any?(:telemetry.list_handlers([:reactive_dag, :cascade, :stop]), &(&1.id == @handler))
  end

  @doc false
  # Runs in the CASCADE's process, which is inside its transaction. Keep it
  # trivial: no queries, no rendering, and never let a broadcast failure
  # propagate — a dashboard that cannot be reached must not roll back the
  # cascade that was only informing it.
  def handle([:reactive_dag, :cascade, :step], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:cascade_step, metadata.cell, metadata.changed_keys})
  end

  def handle([:reactive_dag, :cascade, :stop], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:cascade_done, metadata.report})
  end

  def handle([:reactive_dag, :cascade, :exception], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:cascade_failed, metadata.reason})
  end

  # THE CASCADE STOPPED HERE. Not a failure — the branch reached work that
  # cannot be done inline (`:expensive`) or needs a person (`:approval`), and
  # everything else carried on and committed.
  #
  # `waiting` is the RESOURCE name the suspension was recorded under, which is
  # what `Insights.pending/1` and `Suspension.points/1` also key on; `cell` is
  # the graph's own id for the same node. Both travel because the page knows
  # cells and the suspension table knows resources, and joining them anywhere
  # else would need a lookup this handler must not do.
  def handle([:reactive_dag, :cascade, :suspended], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(
      pubsub,
      {:suspended, metadata[:cell], metadata[:waiting], metadata[:reason],
       measurements[:count] || 0}
    )
  end

  # A resumption job picked a stopping point back up. `suspensions` is how many
  # had piled up there — the count that climbs when nothing is clearing a point.
  def handle([:reactive_dag, :cascade, :resumed], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(
      pubsub,
      {:resumed, metadata[:cell], metadata[:waiting], measurements[:suspensions] || 0}
    )
  end

  # …and cleared it. `discharged` is how many suspensions the job actually
  # removed, which is not necessarily how many it found: one written DURING the
  # resumption is deliberately left behind for the next pass.
  def handle([:reactive_dag, :cascade, :resumption_done], measurements, metadata, %{
        pubsub: pubsub
      }) do
    broadcast(
      pubsub,
      {:resumption_done, metadata[:cell], metadata[:waiting], measurements[:discharged] || 0}
    )
  end

  # ONE cell, not the cascade. Its savepoint rolled back and the branch below it
  # stopped, but everything else carried on and committed — so this is "this cell
  # did not run", not "the cascade broke". A page conflating the two would either
  # understate a broken source or overstate a transient one.
  #
  # Note what recovery now means: there is no dirty queue holding the work, so
  # nothing retries this automatically. The change comes back when its source
  # observes it again.
  def handle([:reactive_dag, :cascade, :cell_failed], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:cell_failed, metadata.cell, metadata.reason})
  end

  def handle([:reactive_dag, :scan, :start], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:scan_started, metadata.cell})
  end

  # `changed`, `unreachable` and `detail` — not the whole report. What a page
  # needs is "did this poll find anything, could it see everything, and what did
  # it cost", and a scan that found nothing must arrive as an event rather than
  # as silence.
  #
  # `detail` is what the SCANNER reported about its own work. It matters for a
  # crawler that calls a model — classifying each new document, say — because
  # that spend appears in no cascade step: the poll and the propagation it
  # enqueues are separate jobs now, so this event is the only place it can reach
  # a live page.
  def handle([:reactive_dag, :scan, :stop], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:scan_done, metadata.cell, scan_run(measurements, metadata)})
  end

  def handle([:reactive_dag, :scan, :exception], _measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:scan_failed, metadata.cell, metadata.reason})
  end

  # A scanner emits this per unit of work — 700 times in a real crawl — because
  # batching would push an arbitrary N into every scanner. Coalescing is THIS
  # side's job: the LiveView already flushes on a 150ms timer, so those 700
  # become a handful of renders.
  # A cell BEGAN. The counterpart to `:cascade, :step`, and the event that lets a
  # page name the cell that is running rather than the last one that finished.
  def handle([:reactive_dag, :cascade, :cell_start], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(pubsub, {:cell_running, metadata[:cell], measurements[:claimed]})
  end

  # An op emits this per unit of work, so it arrives many times in one recompute.
  # Coalescing is THIS side's job, same as `:scan, :progress`.
  def handle([:reactive_dag, :cascade, :progress], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(
      pubsub,
      {:cell_progress, metadata[:cell], measurements.done, measurements[:total],
       metadata[:label]}
    )
  end

  def handle([:reactive_dag, :scan, :progress], measurements, metadata, %{pubsub: pubsub}) do
    broadcast(
      pubsub,
      # `label` too: `Source.progress/3` has always accepted one ("34/721
      # documents") and this dropped it, so the page could only ever count
      # anonymous units. It is also what lets a scanner name the PHASE it is in —
      # a crawl that has fetched everything and is now writing rows reads as a
      # stall otherwise, because the fetch counter has stopped at n/n.
      {:scan_progress, metadata[:cell], measurements.done, measurements[:total],
       metadata[:label]}
    )
  end

  # The `%ReactiveDag.ScanRun{}` the worker put on the event, whole.
  #
  # This used to rebuild a plain map from three of its fields and flatten
  # `changed` to a COUNT — which cost the queued path its wording. A poll that
  # reconciles reports `detail:` (`created`/`updated`/`revived`/`retired`), so
  # the same scan run from the button said "2 new, 1 updated, 1 withdrawn" and
  # run from a job said "3 keys changed". Same data, two renderers, and the
  # worse one was the one people use.
  #
  # A source that predates the struct — a host on an older library, or a
  # hand-fired event in a test — still gets a `%ScanRun{}` built from the flat
  # keys, so one consumer covers both.
  defp scan_run(_measurements, %{run: %ReactiveDag.ScanRun{} = run}), do: run

  defp scan_run(measurements, metadata) do
    %ReactiveDag.ScanRun{
      cell: Map.get(metadata, :cell),
      # `changed` is a LIST on the struct and the event's measurement is a
      # COUNT, so a synthesised run cannot fill it honestly — it does not have
      # the key names. An empty list would claim "nothing changed" over a scan
      # that changed things, so the count rides in `detail` where a renderer
      # can find it and the list stays truthfully empty.
      changed: [],
      detail:
        metadata
        |> Map.get(:detail, %{})
        |> Map.put_new(:changed_count, Map.get(measurements, :changed, 0)),
      unreachable: Map.get(metadata, :unreachable, []),
      # Nil for anything the library produces: a scan enqueues a cascade rather
      # than running one, so there is no report to attach. Kept because a host
      # MAY populate it — a wrapper running a cascade synchronously — and a
      # renderer downstream already has to nil-guard it either way.
      report: Map.get(metadata, :report)
    }
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
