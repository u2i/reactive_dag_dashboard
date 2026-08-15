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

  describe "downstream — where a change goes" do
    test "expands every path, repeating the shared cell", %{plan: plan} do
      tree = Tree.downstream(plan, "expenses")

      ids = tree |> Tree.flatten() |> Enum.map(& &1.id)

      # all_verdicts appears TWICE — once per route through the diamond
      assert Enum.count(ids, &(&1 == "all_verdicts")) == 2
      assert Enum.sort(Enum.uniq(ids)) ==
               ["all_verdicts", "category_health", "expenses", "spend_rollup"]
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
      # two ways for a change to reach the tip
      assert plan |> Tree.downstream("expenses") |> Tree.path_count() == 2
    end

    test "a sink has no downstream", %{plan: plan} do
      tree = Tree.downstream(plan, "all_verdicts")

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
      down = plan |> Tree.downstream("expenses") |> Tree.path_count()
      up = plan |> Tree.upstream("all_verdicts") |> Tree.path_count()

      assert down == up
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

  describe "roots and sinks" do
    test "roots/1 finds the cells a change starts from", %{plan: plan} do
      assert Tree.roots(plan) == ["expenses"]
    end

    test "sinks/1 finds the cells nothing consumes", %{plan: plan} do
      assert Tree.sinks(plan) == ["all_verdicts"]
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
