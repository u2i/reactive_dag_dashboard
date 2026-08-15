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

    test "the shared cell appears ONCE PER PATH in the rendered page" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      # this is the assertion the whole view exists for: all_verdicts is one
      # cell reached two ways, and both ways are on the page
      rows = Regex.scan(~r/class="rdd-row[^"]*"[^>]*>.*?all_verdicts/s, html)
      assert length(rows) == 2
    end

    test "the second occurrence is marked as a repeat" do
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

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
      {:ok, _view, html} = live(build_conn(), "#{@path}/from/expenses")

      assert html =~ "2 paths"
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
      {:ok, _view, html} = live(build_conn(), "#{@path}/into/all_verdicts")

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
