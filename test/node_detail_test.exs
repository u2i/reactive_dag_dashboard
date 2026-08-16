defmodule ReactiveDagDashboard.NodeDetailTest do
  @moduledoc """
  Everything worth knowing about one node, assembled once.

  The old drawer showed an id, inputs and a key count — enough to confirm a node
  exists, not enough to understand what it does or whether it is working. The
  four things that answer "what processing is happening here" are all already
  available; this only assembles them.
  """
  use ExUnit.Case, async: false

  alias ReactiveDagDashboard.{FixtureGraph, NodeDetail}

  setup do
    start_supervised!(%{
      id: FixtureGraph.ExpenseScan,
      start: {FixtureGraph.ExpenseScan, :start_link, []}
    })

    start_supervised!(%{
      id: ReactiveDagDashboard.FakeRepo,
      start: {ReactiveDagDashboard.FakeRepo, :start_link, []}
    })

    prev = Application.get_env(:reactive_dag, :repo)
    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)
    on_exit(fn -> Application.put_env(:reactive_dag, :repo, prev) end)

    ReactiveDag.Insights.forget_reports()
    FixtureGraph.seed()
    :ok
  end

  defp plan, do: FixtureGraph.plan()

  describe "what it does" do
    test "a declarative node is described by its algebra" do
      detail = NodeDetail.build(plan(), "category_health")

      assert detail.algebra.label == "reduce by :category"
      assert NodeDetail.headline(detail) == "reduce by :category"
    end

    test "a per_key node names its action and what it compares" do
      detail = NodeDetail.build(plan(), "expense_notes")

      assert detail.algebra.label == "per_key :describe"
      assert detail.algebra.detail == "fingerprint :amount"
    end
  end

  describe "what it holds" do
    test "the key count, and WHY it is what it is" do
      detail = NodeDetail.build(plan(), "expenses")

      assert detail.status.key_count == 2
      assert detail.status.rows == :stored
    end

    test "a node keeping its rows elsewhere says so, rather than looking broken" do
      detail = NodeDetail.build(plan(), "published")

      assert detail.status.rows == :elsewhere
    end
  end

  describe "where it sits" do
    test "inputs and outputs, both directions from one call" do
      detail = NodeDetail.build(plan(), "category_health")

      assert detail.inputs == ["expenses"]
      assert detail.outputs == ["all_verdicts"]
    end

    test "a leaf has no inputs and a sink no outputs" do
      assert NodeDetail.build(plan(), "expenses").inputs == []
      assert NodeDetail.build(plan(), "verdict_audit").outputs == []
    end
  end

  describe "what it recently did — the part a graph picture cannot show" do
    test "steps carry duration, keys and what triggered them" do
      ReactiveDag.Frontier.mark_dirty("expenses", ["e1"], "test")

      {:ok, report} =
        ReactiveDag.Drain.run(plan(),
          recompute: ReactiveDag.Node.Recompute,
          key_rule: ReactiveDag.Node.KeyRule
        )

      ReactiveDag.Insights.record(report)

      detail = NodeDetail.build(plan(), "category_health")

      assert [step | _] = detail.steps
      assert step.triggered_by == "expenses", "the causal link a static graph lacks"
      assert is_integer(step.duration_us)
      assert detail.last_run
    end

    test "a node that has not run has no steps, and says nothing rather than zero" do
      detail = NodeDetail.build(plan(), "category_health")

      assert detail.steps == []
      refute detail.last_run
    end
  end

  describe "sources/2 — one row per scanner" do
    test "a scanner appears ONCE, however many cells it writes" do
      # the duplicate-heading bug: a source feeding two leaves printed its
      # origin twice, once above each cell, reading as two independent sources
      # of the same name
      controls = ReactiveDag.Source.controls(plan())
      sources = NodeDetail.sources(plan(), controls)

      names = Enum.map(sources, & &1.module)
      assert names == Enum.uniq(names)
    end

    test "and carries what it feeds, so the reach is visible" do
      controls = ReactiveDag.Source.controls(plan())

      council =
        NodeDetail.sources(plan(), controls)
        |> Enum.find(&(&1.module == FixtureGraph.CouncilScan))

      assert "minutes" in council.feeds
      assert "resolutions" in council.feeds
    end

    test "labelled by the scanner's own origin where it offers one" do
      controls = ReactiveDag.Source.controls(plan())

      council =
        NodeDetail.sources(plan(), controls)
        |> Enum.find(&(&1.module == FixtureGraph.CouncilScan))

      assert council.origin == "Council portal"
      assert council.every == nil
    end

    test "a cadence is carried, for the column that compares them" do
      controls = ReactiveDag.Source.controls(plan())

      expenses =
        NodeDetail.sources(plan(), controls)
        |> Enum.find(&(&1.module == FixtureGraph.ExpenseScan))

      assert expenses.every == "0 * * * *"
    end
  end

  test "an unknown cell is nil, not a crash" do
    refute NodeDetail.build(plan(), "nope")
  end
end
