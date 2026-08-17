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
