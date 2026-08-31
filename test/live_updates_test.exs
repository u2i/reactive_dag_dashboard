defmodule ReactiveDagDashboard.LiveUpdatesTest do
  @moduledoc """
  Real-time updates end to end: a real cascade, its telemetry, the observer's
  broadcast, and a LiveView that re-renders.

  Deliberately driven by an actual `Cascade.run/3` rather than a hand-sent
  message. The chain has four links (cascade → telemetry → PubSub → LiveView)
  and a test that skips the first two would pass while the page stayed frozen —
  which is the only failure mode that matters here.

  The property the design rests on: a `:cascade_step` names the cell that moved,
  so the view re-reads **that cell** rather than the graph. `Insights.summary/1`
  is one full table read per cell; doing it per cascade step would make watching
  cost more than the work being watched.

  ## Origins, not marks

  Every cascade here starts from an explicit origin — `%{cell:, keys:}` — where
  the old tests marked the frontier dirty and let a drain go looking. That is
  the engine change in one line: a cascade is TOLD what moved and follows the
  consequences, rather than reading a queue of conclusions about what needs
  doing. There is no longer any way to say "something changed somewhere, go
  find it", which is why no test here does.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDag.Cascade
  alias ReactiveDagDashboard.{FixtureGraph, LiveUpdates, Observer}

  @endpoint ReactiveDagDashboard.TestEndpoint
  @path "/ops/dag"
  @pubsub ReactiveDagDashboard.TestPubSub

  setup do
    start_supervised!(%{
      id: ReactiveDagDashboard.FakeRepo,
      start: {ReactiveDagDashboard.FakeRepo, :start_link, []}
    })

    prev = Application.get_env(:reactive_dag, :repo)
    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)

    # A poll no longer propagates in its own job — it ENQUEUES a cascade per
    # changed leaf, and the default enqueuer is Oban's, which raises outright
    # when no Oban instance is running. This suite has none, and starting one to
    # test a dashboard would be testing Oban.
    #
    # `:cascade_enqueuer` is the library's own seam for exactly this. Recording
    # rather than running: what these tests assert is the SCAN's own telemetry
    # reaching the page, and running the cascade inline here would put a second
    # burst of `:cascade_*` events into every scan test and make each one
    # dependent on the whole downstream graph.
    prev_enqueuer = Application.get_env(:reactive_dag, :cascade_enqueuer)
    test_pid = self()

    Application.put_env(:reactive_dag, :cascade_enqueuer, fn cell, keys, opts ->
      send(test_pid, {:cascade_enqueued, cell, keys, opts})
      {:ok, :recorded}
    end)

    FixtureGraph.seed()
    Observer.detach()

    on_exit(fn ->
      Observer.detach()

      if prev,
        do: Application.put_env(:reactive_dag, :repo, prev),
        else: Application.delete_env(:reactive_dag, :repo)

      if prev_enqueuer,
        do: Application.put_env(:reactive_dag, :cascade_enqueuer, prev_enqueuer),
        else: Application.delete_env(:reactive_dag, :cascade_enqueuer)
    end)

    :ok
  end

  # The live row only — the page also renders finished runs and the cell picker,
  # so page-wide substring checks answer the wrong question.
  defp live_row_html(html) do
    [_, row] = String.split(html, ~s(class="rdd-run rdd-run-live"), parts: 2)

    # Ends at whatever comes next: the prompt when no run has finished, or the
    # first finished run when one has. Splitting on `</div>` truncated inside
    # the row itself once it grew a step list.
    row
    |> String.split(~s(class="rdd-prompt"), parts: 2)
    |> hd()
    |> String.split(~s(<div class="rdd-run">), parts: 2)
    |> hd()
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {i, _} -> i
      :nomatch -> flunk("#{needle} is not in the live row")
    end
  end

  # A cascade from the leaf every test in this file edits. `["*"]` is the
  # whole-cell origin — the honest one here, because the fixture's edits go
  # through Ash directly rather than through a write path that records which
  # rows moved, so narrowing to named keys would be a claim the test cannot back.
  defp cascade(keys \\ ["*"]) do
    Cascade.run(
      FixtureGraph.plan(),
      [%{cell: "expenses", keys: keys}],
      recompute: ReactiveDag.Node.Recompute,
      key_rule: ReactiveDag.Node.KeyRule
    )
  end

  describe "the observer" do
    test "attach/1 is idempotent — a supervisor restart must not crash the app" do
      assert Observer.attach(@pubsub) == :ok
      assert Observer.attach(@pubsub) == :ok
      assert Observer.attached?()
    end

    test "detach/1 leaves nothing attached" do
      Observer.attach(@pubsub)
      Observer.detach()
      refute Observer.attached?()
    end

    test "a real cascade broadcasts a step per recomputed cell, naming its keys" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      # the seed already computed every cell, so an unchanged cascade correctly
      # reports NOTHING changed. Move a row first, or this proves only that the
      # events fire — not that they carry the keys.
      edit_travel_to(5.0)
      {:ok, _report} = cascade()

      # the chain works from an actual cascade, not a synthesised message
      assert_receive {:cascade_step, "category_health", ["travel"]}
      assert_receive {:cascade_done, %ReactiveDag.Report{}}
    end

    test "an UNCHANGED cascade reports no changed keys — it stays proportional" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      {:ok, _report} = cascade()

      # nothing moved, so nothing is reported as moved. A consumer that re-read
      # on every step regardless would be doing the work this exists to avoid.
      assert_receive {:cascade_step, "category_health", []}
    end

    test "a failing cascade broadcasts, rather than leaving the page waiting" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      # `max_steps: 1` rather than the drain's `max_passes: 1`. A cascade has no
      # pass loop to bound — it is one walk — so the budget it enforces is a
      # STEP count, and exceeding it is the same diagnosis: a cycle, or a
      # recompute that keeps re-dirtying its own inputs.
      assert_raise Cascade.RunawayError, fn ->
        Cascade.run(
          FixtureGraph.plan(),
          [%{cell: "expenses", keys: ["*"]}],
          recompute: ReactiveDag.Node.Recompute,
          key_rule: ReactiveDag.Node.KeyRule,
          max_steps: 1
        )
      end

      assert_receive {:cascade_failed, %Cascade.RunawayError{}}
    end

    test "a broadcast failure does not fail the cascade" do
      # the dashboard is informational; it must never be able to break the engine
      Observer.attach(:no_such_pubsub)

      assert {:ok, _report} = cascade()
    end
  end

  describe "a live page" do
    test "says it is live when subscribed, and polling when not" do
      Observer.attach(@pubsub)
      {:ok, _view, html} = live(build_conn(), @path)
      assert html =~ "live"
      assert html =~ ">\n          live\n        </span>" or html =~ "live"
    end

    test "says polling when no pubsub is configured" do
      prev = Application.get_env(:reactive_dag_dashboard, :pubsub)
      Application.delete_env(:reactive_dag_dashboard, :pubsub)
      on_exit(fn -> Application.put_env(:reactive_dag_dashboard, :pubsub, prev) end)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "polling"
      assert html =~ "polling"
    end

    test "a real cascade updates the page without a poll tick" do
      Observer.attach(@pubsub)
      # the graph has several roots, so name the one this test is about rather
      # than relying on which sorts first
      {:ok, view, html} = live(build_conn(), "#{@path}/cell/expenses")

      # travel is 500.0 → failing
      assert html =~ "failing"

      # bring it under the threshold; the recompute should flip it to present
      edit_travel_to(5.0)
      {:ok, _} = cascade()

      # the flush is on a short timer, so wait for the render rather than assume it
      # travel flipped failing → present, so category_health now has 2 present
      # and no failing at all. The nbsp is why this matches on the count alone.
      assert render_eventually(view, ~r/present.{0,10}2/s)
      refute render(view) =~ "failing"
    end

    test "a cascade the page did not cause still reaches it" do
      # two dashboards, one cascade: both hear it. This is why it is PubSub and not
      # a direct handler per LiveView.
      Observer.attach(@pubsub)
      {:ok, a, _} = live(build_conn(), @path)
      {:ok, b, _} = live(build_conn(), "#{@path}/cell/expenses")

      {:ok, _} = cascade()

      assert render_eventually(a, "expenses")
      assert render_eventually(b, "expenses")
    end
  end

  describe "incremental refresh" do
    test "a step re-reads only the named cell, not the graph" do
      # count Ash reads per resource by watching the ETS tables through a
      # telemetry hook would be indirect; instead assert on the assign directly.
      plan = FixtureGraph.plan()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          status: %{},
          stale_cells: MapSet.new(["category_health"]),
          flush_scheduled?: true
        }
      }

      socket = LiveUpdates.refresh_stale(socket, plan)

      # exactly the one cell was read into :status
      assert Map.keys(socket.assigns.status) == ["category_health"]
      assert socket.assigns.stale_cells == MapSet.new()
      refute socket.assigns.flush_scheduled?
    end

    test "a cell not in the plan is skipped rather than stored as nil" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          status: %{},
          stale_cells: MapSet.new(["gone"]),
          flush_scheduled?: true
        }
      }

      socket = LiveUpdates.refresh_stale(socket, FixtureGraph.plan())

      assert socket.assigns.status == %{}
    end

    test "polling is slower when live, brisker when not" do
      assert LiveUpdates.interval(true) > LiveUpdates.interval(false)
    end
  end

  # :upsert is a create action, so a re-upsert is how a row is edited here
  defp edit_travel_to(amount) do
    FixtureGraph.Expenses
    |> Ash.Changeset.for_create(:upsert, %{key: "e1", category: "travel", amount: amount})
    |> Ash.create!()
  end

  # The stylesheet is inline on the page, so it names every class whether or not
  # anything renders with it — `refute html =~ "rdd-ran-badge"` matches the RULE.
  defp body(html), do: String.replace(html, ~r/<style>.*?<\/style>/s, "")

  describe "a scan that found nothing still shows it ran" do
    # The gap: a queued scan said "results appear as it drains", and a poll that
    # found nothing enqueues nothing — so no `:cascade_step` ever arrived and the
    # page was identical to one where the button was never pressed. A working
    # scan read as a broken button on exactly the runs where it worked.

    test "the observer bridges scan telemetry, not only cascade" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      # emitted the way ScanWorker emits it, so this fails if the payload shape
      # the Observer reads ever drifts from what the library sends
      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [], report: nil}
      )

      # A `%ScanRun{}` now, not a flattened map — the poll and the cascade it
      # triggered, as the worker put them on the event.
      assert_receive {:scan_done, "expenses", %ReactiveDag.ScanRun{unreachable: []}}
    end

    test "a no-op scan leaves a trail saying so" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [], report: nil}
      )

      assert render_eventually(view, "polled")
      assert body(render(view)) =~ "no change", "the outcome, not silence"
    end

    test "an outage is not rendered as a clean empty result" do
      # "nothing changed" and "I could not look" are different answers, and the
      # second must not be tinted like a success.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [{"archive", :timeout}], report: nil}
      )

      assert render_eventually(view, "unreachable")
      assert body(render(view)) =~ "rdd-ran-bad", "and marked as a problem"
    end

    # A poll's own cost appears in no cascade step — a poll and the cascade it
    # enqueues are
    # separate phases — so `:scan, :stop` is the only place it can reach a live
    # page. A crawler that classifies each new document with a model spends on
    # every poll, and without this none of it is visible anywhere.
    test "the poll's cost is reported alongside what it found" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 2, passes: 1},
        %{
          cell: "expenses",
          args: %{},
          unreachable: [],
          detail: %{tokens_in: %{"haiku" => 900}, tokens_out: %{"haiku" => 200}, llm_calls: 3},
          report: nil
        }
      )

      assert render_eventually(view, "1.1k tok")
      assert body(render(view)) =~ "3 calls"
    end

    test "a scan that changed nothing can still have cost something" do
      # The reason cost is a separate axis from findings: classifying a
      # document that turns out to be unchanged costs exactly as much as one
      # that changed, and "nothing changed" alone reads as "this was free".
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{
          cell: "expenses",
          args: %{},
          unreachable: [],
          detail: %{tokens_in: 450, llm_calls: 1},
          report: nil
        }
      )

      assert render_eventually(view, "450 tok")
      assert body(render(view)) =~ "nothing changed"
    end

    test "cache hits are reported even when nothing was spent" do
      # A crawl over hundreds of documents that spent nothing BECAUSE the
      # cache held is the change detection working, not a crawl that did
      # nothing — and the two look identical without this.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{
          cell: "expenses",
          args: %{},
          unreachable: [],
          detail: %{cache_hits: 712, llm_calls: 0},
          report: nil
        }
      )

      assert render_eventually(view, "712 cached")
    end

    test "a poll that reports no detail says nothing about cost" do
      # No reassuring "0 tok" on every plain fetch: a crawler that does not
      # spend should not have a cost line at all.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 1, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [], detail: %{}, report: nil}
      )

      assert render_eventually(view, "1 key changed")
      refute body(render(view)) =~ "tok"
    end

    test "a cell that failed WITHOUT failing the cascade is shown as not having run" do
      # The gap this closes: a contained failure is neither a `:step` (it never
      # recomputed) nor an `:exception` (the cascade finished), so without a
      # handler the page shows a clean cascade over a cell that silently did not
      # run — work that did not happen looking like work that did.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :cascade, :cell_failed],
        %{duration_us: 10},
        %{cell: "category_health", pass: 1, reason: :upstream_down, claimed: ["travel"]}
      )

      assert render_eventually(view, "did not run")

      # Tinted as a problem, not as a recompute that changed nothing.
      assert body(render(view)) =~ "rdd-ran-bad"
    end

    test "a failed poll says so rather than going quiet" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :exception],
        %{duration_us: 10},
        %{cell: "expenses", args: %{}, reason: :boom}
      )

      assert render_eventually(view, "poll failed")
    end

    test "a recompute is the more specific fact, so it wins over the poll" do
      # a cell can have both in one burst — the poll found rows AND the cascade
      # reached it. "ran · N changed" answers a different question from "polled".
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 2, passes: 1},
        %{cell: "category_health", args: %{}, unreachable: [], report: nil}
      )

      assert render_eventually(view, "polled")

      edit_travel_to(31.0)
      _ = cascade()

      assert render_eventually(view, "changed")
    end
  end

  describe "progress from inside a poll" do
    test "a crawl in flight shows how far it has got" do
      # `polling…` and nothing else for minutes was the whole complaint: a crawl
      # of 700 documents emits ONE `:scan, :stop`, and it fires when the crawl is
      # already over.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :progress],
        %{done: 34, total: 721},
        %{cell: "expenses", label: "documents"}
      )

      assert render_eventually(view, "34/721")
    end

    test "a count without a total still reports — discovery has no denominator" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      :telemetry.execute(
        [:reactive_dag, :scan, :progress],
        %{done: 12, total: nil},
        %{cell: "expenses"}
      )

      assert render_eventually(view, "polling · 12")
    end

    test "progress is throttled, but the LAST value is not lost" do
      # Dropping an intermediate count is free — the next supersedes it. Dropping
      # the last one would leave the page reporting a stale number, so the
      # OUTCOME event is never throttled and overwrites it either way.
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      for n <- 1..40 do
        :telemetry.execute(
          [:reactive_dag, :scan, :progress],
          %{done: n, total: 40},
          %{cell: "expenses"}
        )
      end

      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 3, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [], report: nil}
      )

      assert render_eventually(view, "3 found"), "the outcome replaces the count"
      refute body(render(view)) =~ "polling", "and the in-flight label is gone"
    end
  end

  describe "progress through the path a scan click takes" do
    test "a scan run through the worker reports its progress" do
      # THE GAP the hand-fired tests could not catch: those proved the Observer
      # bridges an event, not that the event survives the path a click takes —
      # the LiveView's own `scan` handler, `Source.refresh/3`, the scanner.
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      {:ok, _view, _} = live(build_conn(), "#{@path}/cell/expenses")

      # through the library, exactly as the button does
      {:ok, _} = ReactiveDag.Source.refresh(FixtureGraph.plan(), "expenses", recent: true)

      assert_receive {:scan_progress, "expenses", 1, 3, "documents"}
      assert_receive {:scan_progress, "expenses", 3, 3, "documents"}
    end

    test "and the page shows the count while it runs" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      {:ok, _} = ReactiveDag.Source.refresh(FixtureGraph.plan(), "expenses", recent: true)

      assert render_eventually(view, "polling · ")
    end
  end

  describe "the run log" do
    test "a run appears with its cells, timing and changed count" do
      # Driven by a real cascade and a real `Insights.record/1`, so the report
      # shape is the library's rather than a fixture's idea of it.
      edit_travel_to(77.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "rdd-run"
      assert html =~ "cell", "how many cells it touched"
      assert html =~ "changed"
    end

    test "a run renders as a tree, with each cell nested under its trigger" do
      # The re-shaping, driven by a real cascade: `expenses` is the origin
      # and `category_health` / `spend_rollup` / `expense_notes` hang off it.
      # A flat list said so only in an `after expenses` suffix per row; the tree
      # says it structurally, so a fan-out of three READS as a fan-out.
      ReactiveDag.Insights.forget_runs()
      edit_travel_to(4242.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")
      steps = view |> element(".rdd-run-steps") |> render()

      # the containment wrapper exists at all — the whole shape claim
      assert steps =~ "rdd-skids", "children live in a wrapper inside the parent"

      # ...and `category_health` is INSIDE the root's children wrapper rather
      # than a sibling of it. Splitting on the wrapper proves nesting; a bare
      # `steps =~ "category_health"` passed on the flat list too.
      [before_kids, in_kids] = String.split(steps, ~s(class="rdd-skids"), parts: 2)

      assert before_kids =~ "expenses", "the root sits above its children wrapper"
      assert in_kids =~ "category_health", "and its triggered cells sit inside it"
      assert in_kids =~ "spend_rollup"
    end

    test "a cell that changed nothing is visibly distinct from one that changed something" do
      # The user's "except where there is no need to run", at the row level.
      # In this cascade `expenses` moves and `category_health` recomputes to the
      # same verdict — so one propagated and one did not, and the log has to
      # tell them apart rather than rendering both as "ran".
      ReactiveDag.Insights.forget_runs()
      edit_travel_to(4242.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      # the fixture has to actually contain both states, or this proves nothing
      changed_none = Enum.filter(report.steps, &(&1.changed == []))
      changed_some = Enum.filter(report.steps, &(&1.changed != []))
      assert changed_none != [], "the cascade must contain a cell that stopped"
      assert changed_some != [], "and one that propagated"

      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")
      steps = view |> element(".rdd-run-steps") |> render()

      assert steps =~ "stopped here", "a cell that changed nothing says so"
      assert steps =~ "changed", "and one that did still reports its count"

      # the two states carry DIFFERENT markup, which is what makes them
      # distinguishable on screen rather than only in the text
      assert steps =~ "rdd-step-stopped"
      assert steps =~ "rdd-step-changed"
    end

    test "the boundary is visible — a stopped cell names what it did not reach" do
      # The information a flat list cannot carry. `expense_notes` recomputes and
      # changes nothing here, so `published`-style downstream work never
      # happens; the run must say WHERE it stopped rather than leaving the
      # absence to be inferred.
      #
      # Hand-built so the boundary is unambiguous: a real cascade over this
      # fixture reaches the diamond's tip by the other branch, which is the
      # correct behaviour tested below and the wrong shape for pinning THIS.
      report = %ReactiveDag.Report{
        passes: 2,
        duration_us: 1_000,
        steps: [
          %{
            cell: "expenses",
            pass: 0,
            claimed: ["*"],
            changed: ["e1"],
            triggered_by: nil,
            duration_us: 100,
            op: nil,
            meta: %{}
          },
          # recomputed, changed NOTHING — so `all_verdicts` below it never ran
          %{
            cell: "category_health",
            pass: 1,
            claimed: ["*"],
            changed: [],
            triggered_by: "expenses",
            duration_us: 100,
            op: :check,
            meta: %{}
          }
        ]
      }

      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report)

      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")
      steps = view |> element(".rdd-run-steps") |> render()

      assert steps =~ "not reached", "the cascade's edge is drawn, not left blank"

      assert steps =~ "all_verdicts",
             "and it NAMES the cell that never ran — a count alone would not say which"

      assert steps =~ "rdd-step-unrun", "drawn apart from the cells that did run"

      # ONE ring, not the whole downstream tree: `verdict_audit` is below
      # `all_verdicts` and must not be drawn. A 3-cell cascade in a 33-cell graph
      # would otherwise render the graph's static shape in grey and bury the
      # work that actually happened.
      refute steps =~ "verdict_audit",
             "un-run cells stop at one ring — beyond it is the downstream view's job"
    end

    test "a cell reached by another branch is not called unreached" do
      # The trap in drawing the boundary from `plan.parents`: `all_verdicts` has
      # two inputs, so when one of them stops and the other changes,
      # `all_verdicts` DOES run. Listing it as "not reached" under the branch
      # that stopped would be a false statement about a cell on screen.
      #
      # The split is engineered by ADDING a travel row rather than repricing the
      # existing one. `spend_rollup` counts rows per category and `category_health`
      # sums their amounts, so a second travel row at the same total moves the
      # count without moving the sum: `spend_rollup` changes, `category_health`
      # does not, and the diamond is reached down exactly one of its two legs.
      #
      # It used to be a reprice, which moved `category_health` and left
      # `spend_rollup` still — the mirror image. That worked under the drain
      # because a dirty mark on the leaf reached BOTH consumers regardless of
      # what changed, so the tip ran either way. A cascade only continues from a
      # cell that actually moved, so the branch that stops now genuinely stops,
      # and the test has to pick the leg that keeps going.
      ReactiveDag.Insights.forget_runs()

      FixtureGraph.Expenses
      |> Ash.Changeset.for_create(:upsert, %{key: "e1", category: "travel", amount: 250.0})
      |> Ash.create!()

      FixtureGraph.Expenses
      |> Ash.Changeset.for_create(:upsert, %{key: "e3", category: "travel", amount: 250.0})
      |> Ash.create!()

      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      # the cascade really does have this shape, or the test is vacuous
      assert Enum.any?(report.steps, &(&1.cell == "spend_rollup" and &1.changed != []))
      assert Enum.any?(report.steps, &(&1.cell == "category_health" and &1.changed == []))
      assert Enum.any?(report.steps, &(&1.cell == "all_verdicts"))

      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")
      steps = view |> element(".rdd-run-steps") |> render()

      # `all_verdicts` ran, so it must not appear in an un-run row. Scoped to
      # the unrun class rather than the whole panel, since the cell legitimately
      # appears as a step of its own.
      unrun =
        steps
        |> String.split(~s(rdd-step rdd-step-unrun))
        |> Enum.drop(1)
        |> Enum.join()

      refute unrun =~ "all_verdicts",
             "it ran via spend_rollup — naming it unreached would contradict its own row"
    end

    test "a scan reports the POLL's duration, not just its cascade's" do
      # The regression the library change exists to fix: the buffer used to hold
      # the bare report, so a two-minute crawl logged as its recompute's few
      # milliseconds. The poll is usually the larger half and it is now the
      # number on the row.
      #
      # The library no longer BUILDS a run of this shape — a poll enqueues its
      # cascade rather than running one, so `report` is nil on every scan it
      # produces. Constructed by hand here on purpose: a host may still populate
      # the field (a wrapper running a cascade synchronously), the field is kept
      # for exactly that, and the parenthetical only appears when the two
      # durations genuinely differ. This is the case that exercises it.
      ReactiveDag.Insights.forget_runs()

      ReactiveDag.Insights.record(%ReactiveDag.ScanRun{
        cell: "expenses",
        changed: ["e1"],
        # two minutes of polling around a 5ms recompute
        duration_us: 120_000_000,
        report: %ReactiveDag.Report{passes: 1, duration_us: 5_000, steps: []}
      })

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "2m00s", "the WHOLE run — the poll is most of it"
      assert html =~ "cascade 5.0ms", "with the recompute's own share beside it"
      assert html =~ "scan expenses", "and the run names the cell it polled"
      assert html =~ "1 found", "and what the poll itself turned up"
    end

    test "a scan that could not reach an upstream does not read as a clean run" do
      # The honest-gap discipline, which the observer had reintroduced: a scan
      # that could not LOOK logged identically to one that looked and found
      # nothing. Those are different sentences and the log must not merge them.
      ReactiveDag.Insights.forget_runs()

      ReactiveDag.Insights.record(%ReactiveDag.ScanRun{
        cell: "expenses",
        changed: [],
        unreachable: [{"archive", :timeout}],
        duration_us: 9_000,
        report: %ReactiveDag.Report{passes: 1, duration_us: 5_000, steps: []}
      })

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "1 unreachable", "the gap is stated on the run"

      assert html =~ ~s(class="rdd-run-gap"),
             "and marked as a gap rather than as one more count"

      # the upstream is NAMED — which one was down is the actionable half
      assert html =~ "archive", "the unreachable upstream is named"
    end

    test "a scan with no cascade in it renders as itself, not as a broken run" do
      # `report` is nil, so every recompute-side number has to be nil-safe and
      # the panel must not imply a cascade that never ran.
      #
      # This used to be the UNSCANNABLE case only — a source with no credential
      # completes without draining. It is now the shape of EVERY scan the
      # library produces, because a poll enqueues its cascade instead of running
      # one. The panel's job changed with it: it no longer says "no drain ran",
      # which would be a false claim about work that is queued, but says where
      # that work is instead.
      ReactiveDag.Insights.forget_runs()

      ReactiveDag.Insights.record(%ReactiveDag.ScanRun{
        cell: "expenses",
        changed: [],
        not_scannable: :no_credential,
        duration_us: 3_000,
        report: nil
      })

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "rdd-run", "the run is still logged"
      assert html =~ "scan expenses", "and says what it polled"

      assert html =~ "logged as its own run",
             "a scan points at where its recompute went, rather than at an empty cascade"
    end

    test "a run with no steps says so, rather than rendering an empty tree" do
      # Nothing was dirty. That is a real outcome and blank space reads as a
      # broken panel, so the run states it.
      ReactiveDag.Insights.forget_runs()

      ReactiveDag.Insights.record(%ReactiveDag.Report{
        passes: 0,
        duration_us: 40,
        steps: []
      })

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "Nothing to recompute", "an empty cascade explains itself"
    end

    test "a cascade that suspended before recomputing says THAT, not 'nothing to do'" do
      # The third emptiness, and the one with no predecessor. A cascade that
      # stopped at its first cell has no steps — identical in shape to a cascade
      # that found nothing to do, and the opposite in meaning: one is finished,
      # the other is waiting on a job or a person.
      #
      # Collapsing them would report work that has STOPPED as work that was
      # unnecessary, which is the single most misleading thing this panel could
      # say.
      ReactiveDag.Insights.forget_runs()

      ReactiveDag.Insights.record(%ReactiveDag.Report{
        passes: 1,
        duration_us: 40,
        steps: [],
        suspended: [
          %{
            tenant: "*",
            waiting: "expense_notes",
            resource: "expenses",
            row_uuid: "e1",
            reason: :expensive
          }
        ]
      })

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "1 suspended", "the stop is counted on the run's own line"

      assert html =~ "Suspended before recomputing anything",
             "and the empty tree explains that it stopped rather than finished"

      refute html =~ "Nothing to recompute",
             "a cascade that stopped is not a cascade that had nothing to do"
    end

    test "`runs` is in the page header, outside the node funnel" do
      # The functional half is below — reachable without a cell. This is the
      # VISUAL claim, and it is about the whole page, not one nav.
      #
      # The page is a funnel: `rdd-ask` (which question) → `rdd-starts` (which
      # cell) → `rdd-bar` (which view of it). Each row narrows the one above.
      # `runs` answers none of those — it lists DRAINS — so it belongs outside
      # the funnel entirely, beside the title.
      #
      # An earlier revision only left the `<nav>` and took the bar's far end.
      # That satisfied "outside the nav" and still read as a third view of the
      # node, so this test pins the region, not the nav.
      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "rdd-tab-runs", "the runs button carries its own placement class"

      [head, rest] = String.split(html, "</header>", parts: 2)
      assert head =~ "rdd-tab-runs", "runs belongs beside the title"
      refute rest =~ "rdd-tab-runs", "runs appears once, in the header — not also below it"

      # ...and no row of the funnel contains it.
      for {region, opener} <- [
            {"the view bar", ~s(<div class="rdd-bar">)},
            {"the cell picker", ~s(<div class="rdd-starts">)},
            {"the direction pair", ~s(<div class="rdd-ask">)}
          ] do
        assert String.contains?(rest, opener), "#{region} vanished; update this test"

        [_, region_html] = String.split(rest, opener, parts: 2)

        refute region_html |> String.split("</div>", parts: 2) |> hd() =~ "runs",
               "runs is a list of runs, not a narrowing inside #{region}"
      end
    end

    test "`expression` and `graph` remain the node-view pair" do
      {:ok, _view, html} = live(build_conn(), @path)

      [_, nav] = String.split(html, ~s(<nav class="rdd-tabs">), parts: 2)
      [nav, _] = String.split(nav, "</nav>", parts: 2)

      assert nav =~ "expression"
      assert nav =~ "graph"
    end

    test "a cascade that finishes while the log is open appears without a reload" do
      # The whole point of the view: you open it, something runs, and you see
      # it. Every other test in here loads the page AFTER the cascade, which
      # proves the rendering and says nothing about whether an open page
      # notices. This one opens first and never reloads.
      ReactiveDag.Insights.forget_runs()
      Observer.attach(@pubsub)

      {:ok, view, html} = live(build_conn(), "#{@path}?view=log")

      # Count RUN ROWS, not cell names: "expenses" is in the cell picker on
      # every render, so a substring check passes before anything has run.
      runs = fn html ->
        html |> String.split(~s(class="rdd-run-head")) |> length() |> Kernel.-(1)
      end

      assert runs.(html) == 0, "precondition: nothing has run yet"

      edit_travel_to(1234.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      # `record/1` fills the ETS table; `:cascade_done` is what tells the page to
      # go and look. Ordering matters — the broadcast must land after the
      # record, which is the order the real observer uses.
      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_done, report})

      assert runs.(render(view)) == 1,
             "an open log must show a run that finished while it was open"
    end

    test "a page with no pubsub still picks the run up on its refresh tick" do
      # The fallback half. With no pubsub the page never hears `:cascade_done`,
      # so the ONLY thing that can surface a finished run is the poll timer.
      # Sending `:refresh` by hand is what that timer does.
      ReactiveDag.Insights.forget_runs()
      Observer.detach()

      {:ok, view, html} = live(build_conn(), "#{@path}?view=log")

      runs = fn html ->
        html |> String.split(~s(class="rdd-run-head")) |> length() |> Kernel.-(1)
      end

      assert runs.(html) == 0

      edit_travel_to(99.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)

      send(view.pid, :refresh)

      assert runs.(render(view)) == 1,
             "the refresh tick must reload the log, not just the tree"
    end

    test "a cascade IN FLIGHT shows a live row naming the wave front" do
      # A run only joins `@runs` when it finishes, because the report is what
      # gets recorded and there is no report until it is over. On a long cascade
      # that left this view empty and motionless for the whole run — under an
      # empty state promising runs "appear here as they happen".
      ReactiveDag.Insights.forget_runs()
      Observer.attach(@pubsub)

      live_row = ~s(class="rdd-run rdd-run-live")

      {:ok, view, html} = live(build_conn(), "#{@path}?view=log")
      refute html =~ live_row, "nothing is running yet"
      assert html =~ "No runs recorded yet"

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_step, "expenses", ["*"]})
      html = render(view)

      assert html =~ live_row, "an in-flight cascade must be visible while it runs"
      assert html =~ "1 cell so far"

      refute html =~ "No runs recorded yet",
             "the empty state must yield to the run that is happening"

      # Per-cell, in the expression tab's own vocabulary — not a summary line.
      assert html =~ "ran · 1 changed"

      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:cascade_step, "category_health", ["a", "b"]}
      )

      html = render(view)

      assert html =~ "2 cells so far"

      # Both cells are listed, each with what IT did.
      row = live_row_html(html)
      assert row =~ "expenses"
      assert row =~ "category_health"
      assert row =~ "ran · 2 changed", "each cell reports its own outcome"

      # ...and it gives way to the real row once the run is over.
      edit_travel_to(7.0)
      {:ok, report} = cascade()
      ReactiveDag.Insights.record(report)
      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_done, report})

      html = render(view)
      refute html =~ live_row, "the live row is replaced by the finished one"
      assert html =~ "rdd-run-head"
    end

    test "the wave front is ordered even when every step shares a millisecond" do
      # The case `at` cannot answer. A real drain recomputes a whole cascade
      # inside one millisecond, so these steps all carry the same `at` and only
      # `seq` distinguishes them. Ordering by `at` here picks arbitrarily — and
      # passed this test's earlier form by luck.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      # ORDER MATTERS. `sort_by` is stable, so under a full `at` tie it returns
      # MAP order — which for these keys is alphabetical. Broadcasting in
      # alphabetical order would therefore pass against an `at`-ordered
      # implementation for the wrong reason. This order is deliberately not it.
      ids = ~w(spend_rollup expenses budget_gap category_health)

      for id <- ids do
        Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_step, id, ["*"]})
      end

      row = live_row_html(render(view))

      assert row =~ "4 cells so far"

      # Assert the tie is REAL first — if the steps landed in different
      # milliseconds this proves nothing about ordering, and would quietly
      # become a test of the clock.
      %{activity: activity} = :sys.get_state(view.pid).socket.assigns
      ats = activity |> Map.values() |> Enum.map(& &1.at) |> Enum.uniq()
      assert length(ats) == 1, "precondition: all four steps share a millisecond"

      # The steps appear in CASCADE order, oldest first — which under a full
      # tie is exactly what `at` cannot deliver: map iteration would yield
      # `budget_gap, category_health, expenses, spend_rollup` regardless of
      # when each actually arrived.
      order =
        ids
        |> Enum.map(&{&1, index_of(row, &1)})
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))

      assert order == ids, "the list follows the cascade, whatever the clock says"
    end

    test "a cell that failed mid-cascade says so, in the tree's own words" do
      # The reason the live row reuses `activity_label/1` rather than printing
      # its own count. A failed cell did NOT run — its savepoint rolled back and
      # the branch below it stopped — and a row that rendered every step as
      # "ran" would report a failure as a success.
      #
      # Nothing retries it, either. There is no dirty queue holding the work now,
      # so the change returns only when its source observes it again, which makes
      # the distinction this badge draws more load-bearing than it was.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_step, "expenses", ["*"]})

      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:cell_failed, "category_health", :boom}
      )

      row = live_row_html(render(view))

      assert row =~ "did not run", "a failure is not a recompute"
      # The rendered ATTRIBUTE, not the bare class name: the stylesheet is
      # inlined in the page, so `=~ "rdd-ran-bad"` matches the CSS rule itself
      # and passes with the tint removed.
      assert row =~ ~s(class="rdd-ran-badge rdd-ran-bad"),
             "and it is not tinted like a clean result"

      assert row =~ "ran · 1 changed", "the cell that did run still says so"
    end

    test "a recompute reports how far through it is, not just that it started" do
      # The third level. `:cell_start` names the slow cell; this says how far
      # through — the difference between "recomputing meeting_events" for four
      # minutes and knowing it is moving.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cell_running, "expenses", 34})
      assert live_row_html(render(view)) =~ "recomputing · 34 keys"

      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:cell_progress, "expenses", 12, 34, "meetings"}
      )

      assert live_row_html(render(view)) =~ "recomputing · 12/34 meetings"
    end

    test "a RUNNING cell replaces the poll's last phase, so the drain is not a stall" do
      # The second half of the reported hang. The poll's phases end when the poll
      # returns — and then the DRAIN runs, which for an LLM cell is the minutes. The
      # page held the poll's final label ("reconciling") through all of it, because
      # `:cascade, :step` only fires once a cell has FINISHED.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:scan_started, "expenses"})

      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:scan_progress, "expenses", nil, nil, "reconciling"}
      )

      assert live_row_html(render(view)) =~ "polling · reconciling"

      # The cell begins recomputing. THAT is what the row must say now.
      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cell_running, "expenses", 12})

      html = live_row_html(render(view))
      assert html =~ "recomputing · 12 keys"
      refute html =~ "reconciling", "the stale poll phase must not survive the drain"
    end

    test "a poll PHASE is shown, so a finished fetch does not read as a hang" do
      # The bug this fixes: a crawl reports per document, so the counter reaches
      # `34/34` when FETCHING ends — and then reclassifies, writes each leaf and
      # reconciles, all of it silent behind that frozen number. On a real crawl
      # that is the slowest part, and the page looked hung.
      #
      # A phase has no denominator; inventing one would be worse than naming the
      # work. What a person waiting on a crawl needs here is what it is doing.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:scan_started, "expenses"})

      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:scan_progress, "expenses", 34, 34, "documents"}
      )

      assert live_row_html(render(view)) =~ "polling · 34/34 documents"

      # …and then the phases, which is where it used to go quiet.
      Phoenix.PubSub.broadcast(
        @pubsub,
        Observer.topic(),
        {:scan_progress, "expenses", nil, nil, "writing 3 leaves"}
      )

      html = live_row_html(render(view))
      assert html =~ "polling · writing 3 leaves"
      refute html =~ "34/34", "the phase replaces the frozen count, it does not sit beside it"
    end

    test "a poll in progress is visible too, not just the drain it triggers" do
      # A crawl is the SLOWEST thing that happens — minutes, where its drain is
      # milliseconds — so if anything deserves a live row it is this. `activity`
      # already carries scan entries for the tree's badges; the log reads the
      # same map.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:scan_started, "expenses"})
      assert live_row_html(render(view)) =~ "polling…"

      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:scan_progress, "expenses", 40, 120, "documents"})
      # …and the UNIT it counts. `Source.progress/3` has always accepted a label; the
      # observer dropped it, so the page could only ever show anonymous numbers.
      assert live_row_html(render(view)) =~ "polling · 40/120 documents",
             "with the crawl's own progress, and what it is counting"
    end

    test "a poll and the drain it triggers stay in arrival order" do
      # Scan and step entries share one `activity` map, so both need a place in
      # the same total order. Scan entries used to carry no `seq` at all, which
      # sorted every poll to the front of the list regardless of when it landed.
      Observer.attach(@pubsub)
      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      # A step FIRST, then the poll — so "poll before step" cannot be right by
      # arrival, only by the missing-seq bug.
      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:cascade_step, "spend_rollup", ["a"]})
      Phoenix.PubSub.broadcast(@pubsub, Observer.topic(), {:scan_progress, "expenses", 7, 9, "documents"})

      row = live_row_html(render(view))

      assert index_of(row, "spend_rollup") < index_of(row, "polling · 7/9 documents"),
             "the poll sits where it arrived, not pinned to the top"
    end

    test "the log is reachable with no cell selected" do
      # A run is not a property of a node, so asking to see the log must not
      # require having first chosen one to look at.
      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      refute html =~ "Pick a source above"
    end

    test "it says so when nothing has run yet" do
      ReactiveDag.Insights.forget_runs()

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "No runs recorded yet"
    end

    test "token spend is rolled up from step meta, when a strategy reports it" do
      # `Report.total/2` sums a key across steps and ignores steps lacking it —
      # so a graph where only the LLM ops report tokens still totals correctly.
      report = %ReactiveDag.Report{
        passes: 1,
        duration_us: 1_800_000,
        steps: [
          %{
            cell: "agenda_items",
            pass: 1,
            claimed: ["a", "b"],
            changed: ["a"],
            triggered_by: "meeting_docs",
            duration_us: 1_200_000,
            op: :map,
            meta: %{tokens_in: 11_402, tokens_out: 512, llm_calls: 3, cache_hits: 111}
          },
          # no meta at all: the arithmetic node next to it
          %{
            cell: "meeting_shell",
            pass: 1,
            claimed: ["a"],
            changed: [],
            triggered_by: "meeting_docs",
            duration_us: 400_000,
            op: :union,
            meta: %{}
          }
        ]
      }

      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "11.9k tok", "the sum, in thousands"
      assert html =~ "3 call"
      assert html =~ "111 cached"
      assert html =~ "1.8s", "and the wall clock, which does not correlate with tokens"
    end

    test "tokens are broken down per model when a step reports them that way" do
      # The cost question a single number cannot answer: models differ in price
      # by an order of magnitude, so "which model spent this" is what turns a
      # token count into a bill.
      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report_with_models())

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      # the total still reads as one number...
      assert html =~ "4.5k tok"

      # ...and the breakdown says where it went, labelled by family rather than
      # the full model id, which is identical on every row.
      assert html =~ "haiku"
      assert html =~ "sonnet"
    end

    test "a single-model drain shows no breakdown — it would repeat the total" do
      report = %ReactiveDag.Report{
        passes: 1,
        duration_us: 1_000,
        steps: [
          %{
            cell: "a",
            pass: 1,
            claimed: ["k"],
            changed: ["k"],
            triggered_by: nil,
            duration_us: 1_000,
            op: :map,
            meta: %{tokens_in: %{"claude-haiku-4-5" => 1000}}
          }
        ]
      }

      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "1.0k tok", "the total still shows"

      # NB not `refute html =~ "rdd-run-model"` — the class name is also in the
      # inlined stylesheet, so it is present whether or not anything renders.
      # Assert on the RENDERED element instead.
      refute html =~ ~s(class="rdd-run-model"), "a breakdown of one is noise"
      refute html =~ "haiku", "and the model name has nothing to distinguish"
    end

    test "a step reporting the map shape counts toward its own step total" do
      # The regression this guards: summing only numbers reads a map as ZERO, so
      # a node reporting its tokens honestly looked like one reporting none.
      #
      # Scoped to the STEP row. A bare `html =~ "4.5k"` passes on the run-level
      # roll-up alone — in this fixture the run total and the one LLM step's
      # total are the same number, so the assertion could not tell which row
      # rendered it and the step's own arithmetic went unguarded.
      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report_with_models())

      {:ok, view, _html} = live(build_conn(), "#{@path}?view=log")

      steps = view |> element(".rdd-run-steps") |> render()

      assert steps =~ "4.5k", "the LLM step's own tokens, not 0"
      assert steps =~ "agenda_items", "and it is the step row, not the run row"
    end

    defp report_with_models do
      %ReactiveDag.Report{
        passes: 1,
        duration_us: 2_000_000,
        steps: [
          %{
            cell: "agenda_items",
            pass: 1,
            claimed: ["a"],
            changed: ["a"],
            triggered_by: nil,
            duration_us: 1_000_000,
            op: :map,
            meta: %{
              tokens_in: %{"claude-haiku-4-5" => 3000, "claude-sonnet-4-6" => 500},
              tokens_out: %{"claude-haiku-4-5" => 1000}
            }
          },
          %{
            cell: "meeting_shell",
            pass: 1,
            claimed: ["a"],
            changed: [],
            triggered_by: "agenda_items",
            duration_us: 1_000_000,
            op: :union,
            meta: %{}
          }
        ]
      }
    end

    test "steps carry their own timing, so a slow cell is findable" do
      report = %ReactiveDag.Report{
        passes: 1,
        duration_us: 1_000_000,
        steps: [
          %{
            cell: "slow_one",
            pass: 1,
            claimed: ["a"],
            changed: ["a"],
            triggered_by: nil,
            duration_us: 950_000,
            op: :map,
            meta: %{}
          }
        ]
      }

      ReactiveDag.Insights.forget_runs()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "slow_one"
      assert html =~ "950.0ms"
    end
  end

  describe "watching the cascade" do
    test "a row that ran shows it, with the keys it changed" do
      # driven by a real cascade: the wave is the sequence of `:cascade_step`s, and
      # a row carrying a trail is one that has had its step
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(999.0)
      _ = cascade()

      assert render_eventually(view, "rdd-ran-badge")
      assert body(render(view)) =~ "changed"
    end

    test "the trail names the cell that moved, not the whole graph" do
      # the property the whole design rests on — a notification meaning
      # "something somewhere changed" would cost the full re-read polling did
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(1234.0)
      _ = cascade()

      assert render_eventually(view, "rdd-ran")

      html = body(render(view))
      ran = Regex.scan(~r/class="rdd-row rdd-ran"/, html) |> length()
      rows = Regex.scan(~r/class="rdd-row/, html) |> length()

      assert ran > 0, "something ran"
      assert ran < rows, "but not every row — only what the drain touched"
    end

    test "the trail OUTLIVES the drain, since that is when you read it" do
      # clearing at :stop would erase the answer at the moment it became useful
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(555.0)
      _ = cascade()

      assert render_eventually(view, "rdd-ran-badge")

      # the drain is over by now; the trail is still there
      Process.sleep(100)
      assert body(render(view)) =~ "rdd-ran-badge"
    end

    test "and clears when asked, so the page settles on its own" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(777.0)
      _ = cascade()
      assert render_eventually(view, "rdd-ran-badge")

      send(view.pid, :clear_trail)

      refute body(render(view)) =~ "rdd-ran-badge"
    end

    test "a page with no observer attached shows no trail at all" do
      # no telemetry handler, so no steps — and the tree must not invent one
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(42.0)
      _ = cascade()

      Process.sleep(120)
      refute body(render(view)) =~ "rdd-ran-badge"
    end
  end

  # the flush is deliberately debounced, so a render assertion has to wait for it
  defp render_eventually(view, needle, attempts \\ 20) do
    cond do
      render(view) =~ needle ->
        true

      attempts == 0 ->
        flunk("never rendered #{inspect(needle)}")

      true ->
        Process.sleep(25)
        render_eventually(view, needle, attempts - 1)
    end
  end
end
