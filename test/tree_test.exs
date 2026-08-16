defmodule ReactiveDagDashboard.TreeTest do
  @moduledoc """
  `Tree` — the graph fully exploded, one branch per path.

  The fixture is a diamond, which is the only shape that tests anything here:

      expenses ─┬─ category_health ─┐
                │                   ├─ all_verdicts
                └─ spend_rollup ────┘

  `all_verdicts` is ONE cell reached by TWO paths. The whole design question is
  what a view does with that, and the answer this module commits to is: show it
  twice, because a change to `expenses` really does recompute it twice, and a
  view that collapses the two hides the cost.
  """
  use ExUnit.Case, async: true

  alias ReactiveDagDashboard.{FixtureGraph, Tree}

  setup_all do
    {:ok, plan: FixtureGraph.plan()}
  end

  defp find(plan, from, id) do
    plan
    |> Tree.downstream(from)
    |> then(&Tree.levels(plan, &1))
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.find(&(&1.id == id))
  end

  describe "downstream — where a change goes" do
    test "expands every path, repeating the shared cell", %{plan: plan} do
      tree = Tree.downstream(plan, "expenses")

      ids = tree |> Tree.flatten() |> Enum.map(& &1.id)

      # all_verdicts appears TWICE — once per route through the diamond
      assert Enum.count(ids, &(&1 == "all_verdicts")) == 2

      assert Enum.sort(Enum.uniq(ids)) ==
               [
                 "all_verdicts",
                 "category_health",
                 "expense_notes",
                 "expenses",
                 "spend_rollup",
                 "verdict_audit"
               ]
    end

    test "the second occurrence is flagged as a repeat, the first is not", %{plan: plan} do
      [first, second] =
        plan
        |> Tree.downstream("expenses")
        |> Tree.flatten()
        |> Enum.filter(&(&1.id == "all_verdicts"))

      refute first.repeat?
      assert second.repeat?
    end

    test "each occurrence records the edge it arrived by", %{plan: plan} do
      vias =
        plan
        |> Tree.downstream("expenses")
        |> Tree.flatten()
        |> Enum.filter(&(&1.id == "all_verdicts"))
        |> Enum.map(& &1.via)
        |> Enum.sort()

      # this is what collapsing would destroy: WHICH input each path came through
      assert vias == ["category_health", "spend_rollup"]
    end

    test "path_count/1 counts routes, not cells", %{plan: plan} do
      # two ways round the diamond to `all_verdicts`, plus the direct edge to
      # `expense_notes` — three routes over five cells, which is the whole point
      # of counting routes
      assert plan |> Tree.downstream("expenses") |> Tree.path_count() == 3
    end

    test "a sink has no downstream", %{plan: plan} do
      tree = Tree.downstream(plan, "verdict_audit")

      assert tree.children == []
      assert tree.via == nil
      assert tree.depth == 0
    end
  end

  describe "upstream — what feeds this" do
    test "expands every input path, repeating the shared source", %{plan: plan} do
      ids = plan |> Tree.upstream("all_verdicts") |> Tree.flatten() |> Enum.map(& &1.id)

      # expenses feeds BOTH consumers, so it appears twice going up
      assert Enum.count(ids, &(&1 == "expenses")) == 2
    end

    test "it is the mirror of downstream, not a different graph", %{plan: plan} do
      # Mirroring is a claim about the routes BETWEEN two cells, not the totals
      # at each end: `expenses` also feeds `expense_notes`, a route that never
      # reaches this tip. Comparing whole subtrees would set a fan-out against a
      # fan-in and read the difference as a bug.
      down =
        plan
        |> Tree.downstream("expenses")
        |> Tree.flatten()
        |> Enum.count(&(&1.id == "all_verdicts"))

      up =
        plan
        |> Tree.upstream("all_verdicts")
        |> Tree.flatten()
        |> Enum.count(&(&1.id == "expenses"))

      assert down == up
      assert down == 2, "the diamond has two routes, whichever end you count from"
    end

    test "a leaf has no upstream", %{plan: plan} do
      assert Tree.upstream(plan, "expenses").children == []
    end
  end

  describe "depth is the tree's, not the plan's" do
    test "root is 0 and children increment", %{plan: plan} do
      tree = Tree.downstream(plan, "category_health")

      assert tree.depth == 0
      assert Enum.map(tree.children, & &1.depth) == [1]
    end
  end

  describe "hierarchy/2 — structure kept, expanded inline" do
    defp rows(plan, from), do: plan |> Tree.downstream(from) |> then(&Tree.hierarchy(plan, &1))

    test "the root is first, at depth 0", %{plan: plan} do
      [first | _] = rows(plan, "expenses")

      assert first.id == "expenses"
      assert first.depth == 0
    end

    test "children sit one level under their parent", %{plan: plan} do
      rows = rows(plan, "expenses")
      ch = Enum.find(rows, &(&1.id == "category_health"))

      assert ch.depth == 1
      assert ch.via == "expenses"
    end

    test "a converging cell is drawn under EVERY route that reaches it", %{plan: plan} do
      rows = rows(plan, "expenses")
      all = Enum.filter(rows, &(&1.id == "all_verdicts"))

      # both arrivals expanded: what sits under a parent is everything that
      # parent causes, with no cross-reference to chase
      assert length(all) == 2
      assert Enum.map(all, & &1.via) |> Enum.sort() == ["category_health", "spend_rollup"]
    end

    test "and its SUBTREE comes with it, at each arrival", %{plan: plan} do
      # the fact that distinguishes inline expansion from expand-once:
      # `verdict_audit` sits below the diamond's tip, so it must appear under
      # BOTH routes to it, not once
      rows = rows(plan, "expenses")

      assert Enum.count(rows, &(&1.id == "verdict_audit")) == 2,
             "a converging cell's children are drawn at every arrival"
    end

    test "a reference names every parent it is reached from", %{plan: plan} do
      row = Enum.find(rows(plan, "expenses"), &(&1.id == "all_verdicts"))

      assert row.arrivals == ["category_health", "spend_rollup"]
      assert row.routes == 2
    end

    test "a single-route cell reports one route", %{plan: plan} do
      row = Enum.find(rows(plan, "expenses"), &(&1.id == "category_health"))

      assert row.routes == 1
      assert Enum.count(rows(plan, "expenses"), &(&1.id == "category_health")) == 1
    end

    test "last? marks the final child, for drawing the rails", %{plan: plan} do
      rows = rows(plan, "expenses")

      # the root is the only node at depth 0, so it is last
      assert hd(rows).last?
      assert Enum.any?(rows, &(&1.depth > 0 and &1.last?))
      assert Enum.any?(rows, &(&1.depth > 0 and not &1.last?))
    end

    test "every reachable cell appears at least once", %{plan: plan} do
      ids = plan |> rows("expenses") |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()

      assert ids == [
               "all_verdicts",
               "category_health",
               "expense_notes",
               "expenses",
               "spend_rollup",
               "verdict_audit"
             ]
    end

    test "it works upstream too", %{plan: plan} do
      rows = plan |> Tree.upstream("all_verdicts") |> then(&Tree.hierarchy(plan, &1))

      assert hd(rows).id == "all_verdicts"
      assert Enum.count(rows, &(&1.id == "expenses")) == 2, "reached through both consumers"
    end
  end

  describe "levels/2 — one row per cell, for following a source" do
    test "a cell reached twice appears ONCE", %{plan: plan} do
      rows =
        plan
        |> Tree.downstream("expenses")
        |> then(&Tree.levels(plan, &1))
        |> Enum.flat_map(&elem(&1, 1))

      ids = Enum.map(rows, & &1.id)

      assert Enum.count(ids, &(&1 == "all_verdicts")) == 1
      assert length(ids) == length(Enum.uniq(ids)), "no cell renders twice"
    end

    test "and names every edge it arrives by", %{plan: plan} do
      # this is the fact the exploded view spent two rows on, and the reason
      # convergence was invisible: the tip is reached from BOTH consumers
      row = find(plan, "expenses", "all_verdicts")

      assert row.via == ["category_health", "spend_rollup"]
      assert row.routes == 2
    end

    test "a cell on one route names one edge", %{plan: plan} do
      row = find(plan, "expenses", "category_health")

      assert row.via == ["expenses"]
      assert row.routes == 1
    end

    test "distance is the FURTHEST route, so nothing sits above its input", %{plan: plan} do
      levels = plan |> Tree.downstream("expenses") |> then(&Tree.levels(plan, &1))

      at = fn id ->
        Enum.find_value(levels, fn {d, rows} -> if Enum.any?(rows, &(&1.id == id)), do: d end)
      end

      assert at.("expenses") == 0
      assert at.("category_health") == 1
      # reachable at depth 2 via either consumer — never at 1
      assert at.("all_verdicts") == 2
      assert at.("all_verdicts") > at.("spend_rollup")
    end

    test "rows come back grouped and ordered by distance", %{plan: plan} do
      levels = plan |> Tree.downstream("expenses") |> then(&Tree.levels(plan, &1))

      assert Enum.map(levels, &elem(&1, 0)) == Enum.sort(Enum.map(levels, &elem(&1, 0)))
      assert [{0, [%{id: "expenses"}]} | _] = levels
    end

    test "it works upstream too — what feeds this, collapsed", %{plan: plan} do
      rows =
        plan
        |> Tree.upstream("all_verdicts")
        |> then(&Tree.levels(plan, &1))
        |> Enum.flat_map(&elem(&1, 1))

      expenses = Enum.find(rows, &(&1.id == "expenses"))

      assert expenses.routes == 2, "reached through both consumers"
      assert expenses.via == ["category_health", "spend_rollup"]
    end

    test "the collapsed count is cells, not paths", %{plan: plan} do
      tree = Tree.downstream(plan, "expenses")

      cells = tree |> then(&Tree.levels(plan, &1)) |> Enum.flat_map(&elem(&1, 1)) |> length()

      # expenses + category_health + spend_rollup + all_verdicts + expense_notes.
      # 5 cells over 3 routes: the tip is reached twice, so the exploded view
      # spends 6 rows where this spends 5.
      assert cells == 6
      assert Tree.path_count(tree) == 3
      assert tree |> Tree.flatten() |> length() == 8
    end
  end

  describe "roots_by_scanner/1 — which leaves are one crawl" do
    test "a source is ONE root, and its fan-out is graph structure", %{plan: plan} do
      # this used to assert that two leaves grouped under one scanner. The
      # source is now a node, so there is one root and the two cells it feeds
      # are its children — visible in the hierarchy rather than synthesised here
      groups = Tree.roots_by_scanner(plan)

      assert Enum.any?(groups, fn {_label, scanner, ids} ->
               scanner == FixtureGraph.CouncilScan and ids == ["council_portal"]
             end)

      assert Enum.sort(plan.parents["council_portal"]) == ["minutes", "resolutions"]
    end

    test "the group is labelled by the scanner's own origin", %{plan: plan} do
      # "Council portal", not the module name — the picker should read the way
      # the person who declared it thinks about the source
      {label, _scanner, _ids} =
        Enum.find(Tree.roots_by_scanner(plan), &(elem(&1, 1) == FixtureGraph.CouncilScan))

      assert label == "Council portal"
    end

    test "a leaf with its own scanner is its own group", %{plan: plan} do
      {_label, _scanner, ids} =
        Enum.find(Tree.roots_by_scanner(plan), &(elem(&1, 1) == FixtureGraph.ExpenseScan))

      assert ids == ["expenses"]
    end

    test "every root appears exactly once, across all groups", %{plan: plan} do
      grouped = Tree.roots_by_scanner(plan) |> Enum.flat_map(&elem(&1, 2)) |> Enum.sort()

      assert grouped == Tree.roots(plan)
    end

    test "an unscanned root is grouped under nil, not mis-attributed", %{plan: plan} do
      # its keys arrive some other way; that is not a crawl and must not be
      # drawn as one. `expense_notes` is derived, so build a plan whose root
      # declares no scanner at all.
      groups = Tree.roots_by_scanner(plan)

      assert {nil, nil, ["unscanned"]} =
               Enum.find(groups, fn {_l, s, _ids} -> is_nil(s) end),
             "a root with no `scan` gets its own group, labelled by nothing"
    end

    test "unscanned roots sort last", %{plan: plan} do
      scanners = Tree.roots_by_scanner(plan) |> Enum.map(&elem(&1, 1))

      case Enum.find_index(scanners, &is_nil/1) do
        nil -> :ok
        i -> assert i == length(scanners) - 1
      end
    end
  end

  describe "roots and sinks" do
    test "roots/1 finds the cells a change starts from", %{plan: plan} do
      # `minutes` and `resolutions` are no longer roots: they derive from
      # `council_portal`, the source node that holds the crawl
      assert Tree.roots(plan) == ["council_portal", "expenses", "unscanned"]
    end

    test "sinks/1 finds the cells nothing consumes", %{plan: plan} do
      # a scanned leaf nothing consumes is BOTH a root and a sink, which is not a
      # contradiction: it is where change enters and where it stops
      assert Tree.sinks(plan) ==
               [
                 "expense_notes",
                 "minutes",
                 "published",
                 "resolutions",
                 "verdict_audit"
               ]
    end
  end

  describe "a malformed graph must not hang the page" do
    test "a cycle is marked and not descended into" do
      # Graph.build/1 cannot produce this — depths would be impossible — but a
      # dashboard that explains graphs must survive being handed a broken one.
      cyclic = %ReactiveDag.Plan{
        cells: %{
          "a" => %ReactiveDag.Cell{id: "a", inputs: ["b"]},
          "b" => %ReactiveDag.Cell{id: "b", inputs: ["a"]}
        },
        parents: %{"a" => ["b"], "b" => ["a"]},
        depths: %{"a" => 0, "b" => 1}
      }

      nodes = cyclic |> Tree.downstream("a") |> Tree.flatten()

      assert Enum.map(nodes, & &1.id) == ["a", "b", "a"]
      assert List.last(nodes).cyclic?
      # ...and it terminated, which is the actual assertion
    end

    test "fan-in is NOT treated as a cycle", %{plan: plan} do
      # the bug this guards: using one `seen` set for both repeat-marking and
      # cycle-detection prunes the second path through a diamond as if it looped
      refute plan
             |> Tree.downstream("expenses")
             |> Tree.flatten()
             |> Enum.any?(& &1.cyclic?)
    end

    test "a cell not in the plan renders as an empty node", %{plan: plan} do
      tree = Tree.downstream(plan, "nope")

      assert tree.cell == nil
      assert tree.children == []
    end
  end
end
