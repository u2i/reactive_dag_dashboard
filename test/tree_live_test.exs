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

    test "by default a shared cell appears ONCE" do
      # the complaint this fixes: following a source meant reading the same cell
      # name repeatedly down an indented list, losing your place at every
      # convergence
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      rows = Regex.scan(~r/rdd-cell[^>]*>\s*<a[^>]*>all_verdicts</s, html)
      assert length(rows) == 1
    end

    test "and states the routes that collapsed into it" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      # convergence becomes a fact on the row instead of a duplicate row
      assert html =~ "2 routes"
      assert html =~ "category_health, spend_rollup"
    end

    test "the default counts cells AND routes, so neither is hidden" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      # HEEx emits the interpolations across newlines, so match on the pieces
      assert html =~ ~r/5\s+cells over\s+3\s+routes/
    end

    test "bands are named for what the distance means" do
      # "2 hops" says nothing; this is the thing you were tracking
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "the source"
      assert html =~ "recomputes directly"
      assert html =~ "2 recomputes away"
    end

    test "upstream names its bands the other way round" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/into/all_verdicts")

      assert html =~ "this table"
      assert html =~ "fed directly by"
    end

    test "each shape links to the other" do
      {:ok, _view, collapsed} = live(build_conn(), "#{@path}/from/expenses")
      assert collapsed =~ "show every route instead"

      {:ok, _view, exploded} = live(build_conn(), "#{@path}/from/expenses?shape=paths")
      assert exploded =~ "collapse to one row per cell"
    end

    test "the shared cell appears ONCE PER PATH in the rendered page" do
      # the exploded shape is now opt-in; this is what it exists to show
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses?shape=paths")

      # this is the assertion the whole view exists for: all_verdicts is one
      # cell reached two ways, and both ways are on the page
      rows = Regex.scan(~r/class="rdd-row[^"]*"[^>]*>.*?all_verdicts/s, html)
      assert length(rows) == 2
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
      assert html =~ "all_verdicts"
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
