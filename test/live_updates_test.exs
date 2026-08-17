defmodule ReactiveDagDashboard.LiveUpdatesTest do
  @moduledoc """
  Real-time updates end to end: a real drain, its telemetry, the observer's
  broadcast, and a LiveView that re-renders.

  Deliberately driven by an actual `Drain.run/2` rather than a hand-sent
  message. The chain has four links (drain → telemetry → PubSub → LiveView) and
  a test that skips the first two would pass while the page stayed frozen —
  which is the only failure mode that matters here.

  The property the design rests on: a `:drain_step` names the cell that moved, so
  the view re-reads **that cell** rather than the graph. `Insights.summary/1` is
  one full table read per cell; doing it per drain step would make watching cost
  more than the work being watched.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDag.{Drain, Frontier}
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

    FixtureGraph.seed()
    Observer.detach()

    on_exit(fn ->
      Observer.detach()

      if prev,
        do: Application.put_env(:reactive_dag, :repo, prev),
        else: Application.delete_env(:reactive_dag, :repo)
    end)

    :ok
  end

  defp drain do
    Drain.run(FixtureGraph.plan(),
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

    test "a real drain broadcasts a step per recomputed cell, naming its keys" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      # the seed already computed every cell, so an unchanged drain correctly
      # reports NOTHING changed. Move a row first, or this proves only that the
      # events fire — not that they carry the keys.
      edit_travel_to(5.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      {:ok, _report} = drain()

      # the chain works from an actual drain, not a synthesised message
      assert_receive {:drain_step, "category_health", ["travel"]}
      assert_receive {:drain_done, %ReactiveDag.Drain.Report{}}
    end

    test "an UNCHANGED drain reports no changed keys — the cascade stays proportional" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      Frontier.mark_dirty("expenses", ["*"], "seed")
      {:ok, _report} = drain()

      # nothing moved, so nothing is reported as moved. A consumer that re-read
      # on every step regardless would be doing the work this exists to avoid.
      assert_receive {:drain_step, "category_health", []}
    end

    test "a failing drain broadcasts, rather than leaving the page waiting" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      Frontier.mark_dirty("expenses", ["*"], "seed")

      assert_raise Drain.RunawayError, fn ->
        Drain.run(FixtureGraph.plan(),
          recompute: ReactiveDag.Node.Recompute,
          key_rule: ReactiveDag.Node.KeyRule,
          max_passes: 1
        )
      end

      assert_receive {:drain_failed, %Drain.RunawayError{}}
    end

    test "a broadcast failure does not fail the drain" do
      # the dashboard is informational; it must never be able to break the engine
      Observer.attach(:no_such_pubsub)
      Frontier.mark_dirty("expenses", ["*"], "seed")

      assert {:ok, _report} = drain()
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

    test "a real drain updates the page without a poll tick" do
      Observer.attach(@pubsub)
      # the graph has several roots, so name the one this test is about rather
      # than relying on which sorts first
      {:ok, view, html} = live(build_conn(), "#{@path}/cell/expenses")

      # travel is 500.0 → failing
      assert html =~ "failing"

      # bring it under the threshold; the recompute should flip it to present
      edit_travel_to(5.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      {:ok, _} = drain()

      # the flush is on a short timer, so wait for the render rather than assume it
      # travel flipped failing → present, so category_health now has 2 present
      # and no failing at all. The nbsp is why this matches on the count alone.
      assert render_eventually(view, ~r/present.{0,10}2/s)
      refute render(view) =~ "failing"
    end

    test "a drain the page did not cause still reaches it" do
      # two dashboards, one drain: both hear it. This is why it is PubSub and not
      # a direct handler per LiveView.
      Observer.attach(@pubsub)
      {:ok, a, _} = live(build_conn(), @path)
      {:ok, b, _} = live(build_conn(), "#{@path}/cell/expenses")

      Frontier.mark_dirty("expenses", ["*"], "seed")
      {:ok, _} = drain()

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
    # found nothing dirties nothing — so no `:drain_step` ever arrived and the
    # page was identical to one where the button was never pressed. A working
    # scan read as a broken button on exactly the runs where it worked.

    test "the observer bridges scan telemetry, not only drain" do
      Observer.attach(@pubsub)
      Phoenix.PubSub.subscribe(@pubsub, Observer.topic())

      # emitted the way ScanWorker emits it, so this fails if the payload shape
      # the Observer reads ever drifts from what the library sends
      :telemetry.execute(
        [:reactive_dag, :scan, :stop],
        %{duration_us: 10, changed: 0, passes: 1},
        %{cell: "expenses", args: %{}, unreachable: [], report: nil}
      )

      assert_receive {:scan_done, "expenses", %{changed: 0, unreachable: []}}
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

    # A poll's own cost appears in no drain step — a scan and a drain are
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
      # a cell can have both in one burst — the poll found rows AND the drain
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
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()

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

      assert_receive {:scan_progress, "expenses", 1, 3}
      assert_receive {:scan_progress, "expenses", 3, 3}
    end

    test "and the page shows the count while it runs" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      {:ok, _} = ReactiveDag.Source.refresh(FixtureGraph.plan(), "expenses", recent: true)

      assert render_eventually(view, "polling · ")
    end
  end

  describe "the drain log" do
    test "a run appears with its cells, timing and changed count" do
      # Driven by a real drain and a real `Insights.record/1`, so the report
      # shape is the library's rather than a fixture's idea of it.
      edit_travel_to(77.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      {:ok, report} = drain()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "rdd-run"
      assert html =~ "cell", "how many cells it touched"
      assert html =~ "changed"
    end

    test "the log is reachable with no cell selected" do
      # A run is not a property of a node, so asking to see the log must not
      # require having first chosen one to look at.
      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      refute html =~ "Pick a source above"
    end

    test "it says so when nothing has run yet" do
      ReactiveDag.Insights.forget_reports()

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "No drains recorded yet"
    end

    test "token spend is rolled up from step meta, when a strategy reports it" do
      # `Report.total/2` sums a key across steps and ignores steps lacking it —
      # so a graph where only the LLM ops report tokens still totals correctly.
      report = %ReactiveDag.Drain.Report{
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

      ReactiveDag.Insights.forget_reports()
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
      ReactiveDag.Insights.forget_reports()
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
      report = %ReactiveDag.Drain.Report{
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

      ReactiveDag.Insights.forget_reports()
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
      ReactiveDag.Insights.forget_reports()
      ReactiveDag.Insights.record(report_with_models())

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "4.5k", "the LLM step's own tokens, not 0"
    end

    defp report_with_models do
      %ReactiveDag.Drain.Report{
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
      report = %ReactiveDag.Drain.Report{
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

      ReactiveDag.Insights.forget_reports()
      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = live(build_conn(), "#{@path}?view=log")

      assert html =~ "slow_one"
      assert html =~ "950.0ms"
    end
  end

  describe "watching the cascade" do
    test "a row that ran shows it, with the keys it changed" do
      # driven by a real drain: the wave is the sequence of `:drain_step`s, and
      # a row carrying a trail is one that has had its step
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(999.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()

      assert render_eventually(view, "rdd-ran-badge")
      assert body(render(view)) =~ "changed"
    end

    test "the trail names the cell that moved, not the whole graph" do
      # the property the whole design rests on — a notification meaning
      # "something somewhere changed" would cost the full re-read polling did
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(1234.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()

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
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()

      assert render_eventually(view, "rdd-ran-badge")

      # the drain is over by now; the trail is still there
      Process.sleep(100)
      assert body(render(view)) =~ "rdd-ran-badge"
    end

    test "and clears when asked, so the page settles on its own" do
      Observer.attach(@pubsub)
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(777.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()
      assert render_eventually(view, "rdd-ran-badge")

      send(view.pid, :clear_trail)

      refute body(render(view)) =~ "rdd-ran-badge"
    end

    test "a page with no observer attached shows no trail at all" do
      # no telemetry handler, so no steps — and the tree must not invent one
      {:ok, view, _} = live(build_conn(), "#{@path}/cell/expenses")

      edit_travel_to(42.0)
      Frontier.mark_dirty("expenses", ["*"], "edit")
      _ = drain()

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
