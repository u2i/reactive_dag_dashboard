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

  describe "what counts as a change — the other half of the `changed` count" do
    defp compare_plan, do: FixtureGraph.compare_plan()

    test "a node declaring `compare` reports those columns and no others" do
      detail = NodeDetail.build(compare_plan(), "expense_provenance")

      assert detail.compare.basis == :compare
      assert detail.compare.columns == [:status]

      refute :doc_id in detail.compare.columns,
             "provenance is part of the record, not the result"

      refute :ordinal in detail.compare.columns,
             "a re-parse shifts the ordinal without anything having changed"
    end

    test "a node declaring none says every column, which is an ANSWER not an absence" do
      # the reader asking why a cascade fired needs to be TOLD this, not left to
      # infer it from a missing section
      detail = NodeDetail.build(plan(), "category_health")

      assert detail.compare.basis == :every_column
      assert detail.compare.columns == nil
      refute detail.compare.inert
    end

    test "a per_key fingerprint is named as the INPUT skip it is, not as the payload's" do
      # two mechanisms share the word. `per_key`'s `fingerprint:` hashes the
      # inputs to decide whether to re-run the action, then writes with
      # `Ash.create!` — never reaching `Payload`, so neither `compare` nor the
      # payload fingerprint is consulted on that path
      detail = NodeDetail.build(plan(), "expense_notes")

      assert detail.compare.basis == :input_fingerprint
      assert detail.compare.columns == [:amount]
    end

    test "a leaf declaring a top-level fingerprint compares THAT, not its columns" do
      # the mechanism that OUTRANKS compare in `Payload.moved?` — naming the
      # row's columns here would name columns the write never consults
      detail = NodeDetail.build(compare_plan(), "watched")

      assert detail.compare.basis == :fingerprint
      assert detail.compare.columns == [:body]

      refute :last_seen_at in detail.compare.columns,
             "the field that moves on every observation is the one a digest exists to ignore"
    end

    test "a leaf declaring neither is every column, said plainly" do
      detail = NodeDetail.build(plan(), "unscanned")

      assert detail.compare.basis == :every_column
      assert detail.compare.columns == nil
    end

    test "a declaration on a single-aggregate node is marked INERT, not shown as live" do
      # `Aggregate.project/3` builds the row from the key column plus that one
      # aggregate's dest — there is no bookkeeping column to narrow past
      detail = NodeDetail.build(compare_plan(), "expense_tally")

      assert detail.compare.basis == :compare
      assert detail.compare.inert, "one aggregate means `compare` can exclude nothing"
    end

    test "a declaration on an ordinary node is NOT inert" do
      detail = NodeDetail.build(compare_plan(), "expense_provenance")

      refute detail.compare.inert
    end
  end

  test "an unknown cell is nil, not a crash" do
    refute NodeDetail.build(plan(), "nope")
  end
end
