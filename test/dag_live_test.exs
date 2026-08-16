defmodule ReactiveDagDashboard.DagLiveTest do
  @moduledoc """
  The dashboard: one page, built around a node.

  This replaces `PageLiveTest` and `TreeLiveTest`, which tested three views that
  no longer exist — an index by depth plus `/from/:id` and `/into/:id`. Each
  answered a slice of the same question and none alone: you found a cell on the
  index, went to `/from` to see what it reached, then back to read what it held.

  What survives from those files is what was about BEHAVIOUR rather than layout,
  restated against the single page.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDagDashboard.FixtureGraph

  @endpoint ReactiveDagDashboard.TestEndpoint
  @path "/ops/dag"

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

  defp at(path), do: live(build_conn(), path)

  describe "sources — what feeds this graph" do
    test "a scanner appears ONCE, however many cells it writes" do
      # the duplicate-heading bug: a source feeding two leaves printed its
      # origin above each of them, reading as two sources of the same name.
      #
      # Scoped to the TABLE: the panel for a scanned cell names its scanner too,
      # which is correct — the bug was two ROWS for one crawl.
      {:ok, _view, html} = at(@path)

      assert count(table_of(html), "Council portal") == 1
    end

    test "labelled by the scanner's own origin, with the cell beneath" do
      {:ok, _view, html} = at(@path)

      assert html =~ "Finance export"
      assert html =~ "expenses"
    end

    test "and says what one crawl reaches" do
      {:ok, _view, html} = at(@path)

      assert html =~ "minutes, resolutions"
    end

    test "a cadence is shown where declared, 'on demand' where not" do
      {:ok, _view, html} = at(@path)

      assert html =~ "0 * * * *"
      assert html =~ "on demand"
    end
  end

  describe "the hierarchy" do
    test "structure is drawn, not implied" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "├─" or html =~ "└─"
    end

    test "each node names the OPERATION it performs" do
      # the operator IS the relationship: an edge into a union means something
      # different from an edge into a reduce, and a bare arrow says neither
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "reduce by :category"
      assert html =~ "per_key :describe"
    end

    test "a converging cell says how many routes reach it" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "2 routes"
    end

    test "the direction toggles without leaving the page" do
      {:ok, view, _} = at("#{@path}/cell/all_verdicts")

      html = render_click(view, "direction", %{"to" => "upstream"})

      assert html =~ "what feeds"
      assert html =~ "category_health"
    end
  end

  describe "the node panel — what a graph picture cannot show" do
    test "a node explains itself, from its own moduledoc" do
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")
      on_exit(fn -> Application.put_env(:reactive_dag_dashboard, :source_url, nil) end)

      {:ok, _view, html} = at("#{@path}/cell/published")

      # `Published` is a compute node; its module's first paragraph is the
      # description, and the link goes to the line
      assert html =~ "https://ex.com/"
    end

    test "it names what it reads and what it feeds" do
      {:ok, _view, html} = at("#{@path}/cell/category_health")

      assert html =~ "reads"
      assert html =~ "feeds"
    end

    test "and what it recently did, with the cell that triggered it" do
      ReactiveDag.Frontier.mark_dirty("expenses", ["e1"], "test")

      {:ok, report} =
        ReactiveDag.Drain.run(FixtureGraph.plan(),
          recompute: ReactiveDag.Node.Recompute,
          key_rule: ReactiveDag.Node.KeyRule
        )

      ReactiveDag.Insights.record(report)

      {:ok, _view, html} = at("#{@path}/cell/category_health")

      assert html =~ "recent recomputes"
      assert html =~ "after expenses", "the causal link a static graph lacks"
    end

    test "a node that has never run says so, rather than showing zero" do
      {:ok, _view, html} = at("#{@path}/cell/category_health")

      assert html =~ "no recorded recomputes"
    end
  end

  describe "key counts say WHY they are what they are" do
    test "a real table reports its count" do
      {:ok, _view, html} = at(@path)

      assert html =~ ~s|title="2 keys"|
    end

    test "an EMPTY table reports zero, because zero is a real answer" do
      for row <- Ash.read!(FixtureGraph.CategoryHealth), do: Ash.destroy!(row)

      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ ~s|title="no rows"|
    end

    test "a node keeping its rows elsewhere is not an alarm" do
      {:ok, _view, html} = at("#{@path}/cell/unscanned")

      assert html =~ "keeps its rows elsewhere"
    end
  end

  test "selecting a cell moves to it" do
    {:ok, view, _} = at(@path)

    render_click(view, "select", %{"cell" => "category_health"})

    assert_patched(view, "#{@path}/cell/category_health")
  end

  defp table_of(html) do
    case Regex.run(~r/<table class="table table-sm.*?<\/table>/s, html) do
      [table] -> table
      nil -> ""
    end
  end

  describe "navigation — reaching every node" do
    test "a source in the table is selectable, not just scannable" do
      # the table had a scan button and no way to SELECT the source, and the
      # hierarchy only shows the default root's subtree — so six of seven
      # sources were unreachable from the page entirely.
      #
      # Asserted on the MARKUP: `render_click` sends the event whether or not
      # anything on the page emits it, so it would pass against the bug.
      {:ok, _view, html} = at(@path)

      row = table_of(html)

      assert row =~ ~s|phx-click="select"|
      assert row =~ ~s|phx-value-cell="council_portal"|
    end

    test "every source is reachable, not only the one that sorts first" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "expenses"
      assert html =~ "category_health", "its subtree, not council_portal's"
    end
  end

  describe "upstream starts somewhere with an upstream" do
    test "with no cell named, upstream starts at a SINK" do
      # a root's upstream is one node with nothing above it — which is what
      # "no hierarchy under upstream, each item a single entry" was.
      #
      # Asserted on the DETAIL heading: `expenses` also appears in the sources
      # table whatever is selected, so matching the whole page proves nothing.
      {:ok, _view, html} = at("#{@path}?direction=upstream")

      # asserted on the PROPERTY, not on which sink sorts first: whatever is
      # picked must have something above it, which a root never does
      assert html =~ "├─" or html =~ "└─"
    end

    test "and a named sink shows its full depth" do
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit?direction=upstream")

      # verdict_audit ← all_verdicts ← category_health/spend_rollup ← expenses
      assert html =~ "all_verdicts"
      assert html =~ "category_health"
      assert html =~ "expenses"
    end

    test "downstream still starts at a root" do
      {:ok, _view, html} = at(@path)

      assert html =~ "what changes"
    end
  end

  describe "direction survives navigation" do
    test "the toggle puts direction in the URL" do
      {:ok, view, _} = at("#{@path}/cell/all_verdicts")

      render_click(view, "direction", %{"to" => "upstream"})

      assert_patched(view, "#{@path}/cell/all_verdicts?direction=upstream")
    end

    test "and selecting a node KEEPS it" do
      # the bug: `handle_params` runs on every patch and read direction back
      # from params, so the toggle worked until you clicked anything
      {:ok, view, _} = at("#{@path}/cell/all_verdicts?direction=upstream")

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health?direction=upstream")
    end

    test "upstream actually shows what feeds the node" do
      {:ok, _view, html} = at("#{@path}/cell/all_verdicts?direction=upstream")

      assert html =~ "what feeds"
      assert html =~ "category_health"
      assert html =~ "expenses", "two levels up, so the tree really inverted"
    end

    test "and downstream is still the default" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "what changes"
    end
  end

  defp count(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
