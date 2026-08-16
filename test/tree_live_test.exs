defmodule ReactiveDagDashboard.TreeLiveTest do
  @moduledoc """
  The two directional views, rendered through the real router.

  `TreeTest` proves the expansion is right as data. This proves the page shows
  it: the repeated cell has to reach the HTML twice, or the whole point of the
  view is lost somewhere between the tree and the template.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDagDashboard.FixtureGraph

  @endpoint ReactiveDagDashboard.TestEndpoint
  @path "/ops/dag"

  setup do
    FixtureGraph.seed()
    :ok
  end

  describe "where a change goes (/from)" do
    test "with no cell named, it starts at a leaf" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from")

      assert html =~ "Where a change goes"
      assert html =~ "expenses"
    end

    test "a source root is labelled by its origin, not its cell id" do
      # this used to assert "one crawl, 2 leaves" — a synthesised grouping of
      # two leaves sharing a scanner. The source is a node now, so there is one
      # root; what survives is the LABEL, because only the module knows its own
      # name for itself.
      {:ok, _view, html} = live(build_conn(), "#{@path}/from")

      assert html =~ "Council portal", "the scanner's own origin label"
      refute html =~ "one crawl"
    end

    test "a leaf with no scanner says so, rather than being mis-attributed" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from")

      assert html =~ "no scanner declared"
      assert html =~ "unscanned"
    end

    test "upstream is a flat list — sinks have no crawl to group by" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into")

      refute html =~ "one crawl"
      refute html =~ "no scanner declared"
    end

    test "a single-leaf scanner is not labelled as a multi-leaf crawl" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from")

      assert html =~ "Finance export"
      refute html =~ "one crawl, 1 leaves"
    end

    test "the header describes what the body actually does" do
      # it said "each cell expanded once" while rendering every route in full —
      # a caption contradicting the thing it captions
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      refute html =~ "expanded once"
      assert html =~ "every route drawn in full"
    end

    test "each row carries its depth as an indent step" do
      # NOTE: this pins the MARKUP only. The bug it followed was pure CSS —
      # `.rdd li` (0,1,1) beat a bare `.rdd-hier-row` (0,1,0), so rows rendered
      # as full-width bordered boxes and the indent was invisible. The markup was
      # correct throughout, so no assertion on HTML could have caught it; the
      # fix is verified by eye and guarded by the comment in layouts.ex.
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "--indent: 2", "a depth-2 row exists to be indented"
    end

    test "the default is a hierarchy: children under parents" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      # the structure is drawn, not implied by a `via` string in another band
      assert html =~ "└─" or html =~ "├─"
    end

    test "it names the OPERATION each cell performs" do
      # the relationship is the operator: an edge into a union means something
      # different from an edge into a reduce, and a flat arrow says neither
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "reduce by :category"
      assert html =~ "union"
      assert html =~ "per_key :describe"
    end

    test "and what each input IS to its parent" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "alternative", "a union's inputs are alternatives to each other"
      assert html =~ "folded", "a reduce folds its input"
    end

    test "a per_key shows what it compares" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "fingerprint :amount"
    end

    test "a converging cell is drawn under every route that reaches it" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      # inline: the cell appears under BOTH parents, so what sits under a parent
      # is everything that parent causes
      occurrences =
        Regex.scan(~r/class="rdd-row rdd-hier-row"[^>]*>.*?all_verdicts</s, html)

      assert length(occurrences) == 2
      assert html =~ "2 routes in", "and says it is the same cell, reached twice"
    end

    test "by default a shared cell appears ONCE" do
      # the complaint this fixes: following a source meant reading the same cell
      # name repeatedly down an indented list, losing your place at every
      # convergence
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=cells")

      rows = Regex.scan(~r/rdd-cell[^>]*>\s*<a[^>]*>all_verdicts</s, html)
      assert length(rows) == 1
    end

    test "and states the routes that collapsed into it" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=cells")

      # convergence becomes a fact on the row instead of a duplicate row
      assert html =~ "2 routes"
      assert html =~ "category_health, spend_rollup"
    end

    test "the default counts cells AND routes, so neither is hidden" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=cells")

      # HEEx emits the interpolations across newlines, so match on the pieces
      assert html =~ ~r/6\s+cells over\s+3\s+routes/
    end

    test "bands are named for what the distance means" do
      # "2 hops" says nothing; this is the thing you were tracking
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=cells")

      assert html =~ "the source"
      assert html =~ "recomputes directly"
      assert html =~ "2 recomputes away"
    end

    test "upstream names its bands the other way round" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into/all_verdicts?shape=cells")

      assert html =~ "this table"
      assert html =~ "fed directly by"
    end

    test "each shape links to the others" do
      {:ok, _view, cells} = live(build_conn(), "#{@path}/from/expenses?shape=cells")
      assert cells =~ "back to the hierarchy"

      {:ok, _view, exploded} = live(build_conn(), "#{@path}/from/expenses?shape=paths")
      assert exploded =~ "collapse to one row per cell"

      {:ok, _view, tree} = live(build_conn(), "#{@path}/from/expenses")
      assert tree =~ "flat list by distance"
    end

    test "the shared cell appears ONCE PER PATH in the rendered page" do
      # the exploded shape is now opt-in; this is what it exists to show
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=paths")

      # this is the assertion the whole view exists for: all_verdicts is one
      # cell reached two ways, and both ways are on the page
      rows = Regex.scan(~r/class="rdd-row[^"]*"[^>]*>.*?all_verdicts/s, html)
      assert length(rows) == 4, "two arrivals, each now carrying its own subtree row"
    end

    test "the second occurrence is marked as a repeat" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=paths")

      assert html =~ "rdd-repeat-row"
      assert html =~ ">\n              repeat\n            </span>" or html =~ "repeat"
    end

    test "each row says which edge it arrived by" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "via"
      assert html =~ "category_health"
      assert html =~ "spend_rollup"
    end

    test "the path count is stated, and counts routes not cells" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=paths")

      assert html =~ "3 paths"
    end

    test "live state rides along, so a path shows what each cell holds" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "failing"
      assert html =~ "present"
    end
  end

  describe "what feeds this (/into)" do
    test "with no cell named, it starts at a sink" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into")

      assert html =~ "What feeds this"
      assert html =~ "verdict_audit"
    end

    test "the shared source appears once per input path" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into/all_verdicts?shape=paths")

      rows = Regex.scan(~r/class="rdd-row[^"]*"[^>]*>.*?expenses/s, html)
      assert length(rows) == 2
    end

    test "it uses the upstream vocabulary, not the downstream one" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into/all_verdicts")

      assert html =~ "feeds"
      assert html =~ "derived tables"
    end
  end

  describe "navigation" do
    test "the tabs link within the mount prefix, not the root" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from")

      assert html =~ ~s|href="/ops/dag/into"|
      assert html =~ ~s|href="/ops/dag"|
    end

    test "a row links to its own expansion, keeping the direction" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ ~s|href="/ops/dag/from/category_health"|
    end

    test "the index page links to both views" do
      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ ~s|href="/ops/dag/from"|
      assert html =~ ~s|href="/ops/dag/into"|
    end

    test "patching between directions re-renders the other tree" do
      {:ok, view, _html} = live(build_conn(), "#{@path}/from/expenses")

      html = render_patch(view, "#{@path}/into/all_verdicts")

      assert html =~ "What feeds this"
    end
  end
end
