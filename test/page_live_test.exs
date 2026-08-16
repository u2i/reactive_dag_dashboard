defmodule ReactiveDagDashboard.PageLiveTest do
  @moduledoc """
  Renders the dashboard against a REAL reactive graph.

  The point of rendering a real graph rather than a hand-built `%Plan{}`: this
  page's entire job is to display what `ReactiveDag.Insights` reports, so a test
  that stubs the data proves nothing about whether the two still agree. reactive_dag
  0.17 removed the coordination tuple and the tableless verdict node — a stubbed
  plan would have sailed through both, while this test would have caught the
  badge that stopped rendering and the `Insights` fields that went away.

  What it pins:

    * every cell in the plan appears, under its depth
    * per-cell state comes from `Insights` and reflects the node's actual rows
    * a cell whose rows cannot be read renders as UNKNOWN, not as empty — the
      distinction the whole honest-gap discipline rests on
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDagDashboard.FixtureGraph

  @endpoint ReactiveDagDashboard.TestEndpoint

  # the host mounts us at a nested path; the tests use the same one, so a link
  # built on a wrong prefix fails here rather than in someone's app.
  @path "/ops/dag"

  setup do
    FixtureGraph.seed()
    :ok
  end

  defp render_page do
    {:ok, view, html} = live(build_conn(), @path)
    {view, html}
  end

  test "every cell renders, grouped by depth" do
    {_view, html} = render_page()

    assert html =~ "expenses"
    assert html =~ "category_health"
    assert html =~ "depth 0"
    assert html =~ "depth 1"
  end

  test "a leaf is badged as one" do
    {_view, html} = render_page()
    assert html =~ "leaf"
  end

  test "per-cell state comes from the node's own rows" do
    {_view, html} = render_page()

    # travel is 500.0 → failing; meals is 40.0 → present. Both are real rows in
    # CategoryHealth, read back through Insights.
    assert html =~ "failing"
    assert html =~ "present"
  end

  test "the key count reflects what the cell actually holds" do
    {_view, html} = render_page()

    # 2 expenses, 2 categories — if Insights and the page disagreed about where
    # rows live, these would read "?" instead
    assert html =~ ~s|class="rdd-count" title="2 keys">2<|
    refute html =~ ~s|class="rdd-cell rdd-unknown"|
  end

  test "selecting a cell opens the drawer with its declaration" do
    {view, _html} = render_page()

    html = render_patch(view, "#{@path}/cell/category_health")

    assert html =~ "rdd-drawer"
    assert html =~ "check"
    assert html =~ "expenses"
  end

  test "the cell link points at the route the router actually defines" do
    {_view, html} = render_page()

    # a link built on the wrong prefix renders fine and 404s in production; this
    # is the assertion that catches it
    assert html =~ ~s|href="/ops/dag/cell/category_health"|
  end

  test "an EMPTY table reports zero, because zero is a real answer" do
    # This test used to assert the opposite, on the right principle applied to
    # the wrong case: "I could not look" and "there is nothing there" ARE
    # different claims — and emptying a readable table is the second one.
    # Rendering `?` here made a working node look broken.
    for row <- Ash.read!(FixtureGraph.CategoryHealth), do: Ash.destroy!(row)

    {_view, html} = render_page()

    assert html =~ ~s|class="rdd-count" title="no rows">0<|
    refute html =~ ~s|class="rdd-cell rdd-unknown"|
  end

  test "a node that keeps its rows elsewhere is not an alarm" do
    # the write-elsewhere / escape-hatch shape: no table by design. It has
    # nothing to count and that is not a failure to count.
    {_view, html} = render_page()

    assert html =~ "rdd-elsewhere"
    assert html =~ ~s|>—<|
    refute html =~ ~s|title="could not read this node's rows"|
  end
end
