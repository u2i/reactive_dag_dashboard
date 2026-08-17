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

  # The MARKUP, with the inline stylesheet removed.
  #
  # The dashboard ships its own CSS in a `<style>` block on the page, so every
  # class name it defines appears in the response whether or not anything
  # renders with it — and `refute html =~ "rdd-empty"` matches the RULE and
  # fails against perfectly correct markup. Negative assertions have to look at
  # what was rendered, not at what could be.
  defp markup(html), do: String.replace(html, ~r/<style>.*?<\/style>/s, "")

  # Where a string first appears in the MARKUP — the stylesheet mentions every
  # class name, so an index over the whole response measures the CSS.
  defp index_of(html, needle) do
    case :binary.match(markup(html), needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} not found")
    end
  end

  # Just the diagram. The picker lists every cell in the plan, so a question
  # about what the DIAGRAM contains has to be asked of the diagram.
  defp svg_of(html) do
    case Regex.run(~r/<svg.*?<\/svg>/s, html) do
      [svg] -> svg
      nil -> ""
    end
  end

  describe "the picker — choosing what the tree is rooted at" do
    # The page used to render one panel per SOURCE downstream and a single
    # panel rooted at the selection upstream. Two different gestures for one
    # question, and upstream had no picker at all: clicking a node silently
    # re-rooted the page, so the node you clicked vanished into the root
    # position and its siblings disappeared.
    #
    # One picker over every cell, both directions.

    test "offers EVERY cell, not just the two ends" do
      # the reason this exists: half of a real graph is neither source nor
      # sink, and none of it could be a starting point. "What feeds
      # meeting_shell" was unanswerable from the page.
      {:ok, _view, html} = at(@path)

      assert html =~ ~s|phx-value-cell="expenses"|, "a source"
      assert html =~ ~s|phx-value-cell="category_health"|, "a derived cell"
      assert html =~ ~s|phx-value-cell="verdict_audit"|, "an output"
    end

    test "grouped by position, since that is what the three kinds mean" do
      {:ok, _view, html} = at(@path)

      assert html =~ "sources"
      assert html =~ "derived"
      assert html =~ "outputs"
    end

    test "the current root is named on the control" do
      {:ok, _view, html} = at("#{@path}/cell/category_health")

      assert html =~ "rdd-pick"
      assert html =~ "category_health"
    end

    test "picking a cell re-roots the tree" do
      {:ok, view, _} = at(@path)

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health")
    end

    test "the ends that matter for THIS direction come first" do
      # downstream starts at a source, upstream at an output. Leading with the
      # wrong end puts the natural starting points a scroll away.
      {:ok, _view, down} = at(@path)
      {:ok, _view, up} = at("#{@path}/cell/verdict_audit?direction=upstream")

      assert index_of(down, "sources") < index_of(down, "outputs")
      assert index_of(up, "outputs") < index_of(up, "sources")
    end

    test "the same picker serves both directions" do
      # the asymmetry that made clicking feel destructive: downstream had seven
      # source panels as its index and upstream had none
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit?direction=upstream")

      assert html =~ "rdd-pick"
      assert html =~ ~s|phx-value-cell="expenses"|
    end
  end

  describe "a dead end says so" do
    test "a source viewed upstream explains itself rather than rendering empty" do
      # `expenses` has no inputs, so upstream from it is one node with nothing
      # above it. That is an answer, not an error — but an empty panel reads as
      # broken, which is what was reported.
      {:ok, _view, html} = at("#{@path}/cell/expenses?direction=upstream")

      assert html =~ "rdd-empty"
      assert html =~ "is a source"
      assert html =~ "nothing in this graph feeds it"
    end

    test "and offers the direction that does have something" do
      {:ok, view, html} = at("#{@path}/cell/expenses?direction=upstream")

      assert html =~ "see what it reaches"

      render_click(view, "direction", %{"to" => "downstream"})
      assert_patched(view, "#{@path}/cell/expenses")
    end

    test "an output viewed downstream likewise" do
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit")

      assert html =~ "rdd-empty"
      assert html =~ "is an output"
    end

    test "a cell with a tree in that direction is NOT a dead end" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      refute markup(html) =~ "rdd-empty"
      assert html =~ "rdd-row"
    end
  end

  describe "the hierarchy" do
    test "structure is drawn by indent and a collapse chevron" do
      # depth is CONTAINMENT, not a computed margin: a node's children live in
      # a wrapper inside it, which carries the indent and the rail. A flat list
      # pushed right by `margin-left: depth * 26px` rendered the same
      # information with nothing bounding a subtree.
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-children", "children nest in a wrapper"
      assert html =~ "rdd-chev"
      refute markup(html) =~ "margin-left:", "no arithmetic encodes depth any more"
    end

    test "each node names the OPERATION it performs" do
      # the operator IS the relationship: an edge into a union means something
      # different from an edge into a reduce, and a bare arrow says neither
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "reduce( folded: expenses ) by :category"
      assert html =~ "per_key( per row: expenses ) :describe"
    end

    test "a converging cell says how many routes reach it" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "2 routes"
    end

    test "the direction toggles without leaving the page" do
      {:ok, view, _} = at("#{@path}/cell/all_verdicts")

      html = render_click(view, "direction", %{"to" => "upstream"})

      assert html =~ "category_health", "what feeds all_verdicts"
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
      # `published` reads `unscanned` and holds no rows of its own. Upstream
      # from it, so the panel is `published` itself.
      {:ok, _view, html} = at("#{@path}/cell/published?direction=upstream")

      assert html =~ "keeps its rows elsewhere"
    end
  end

  test "selecting a cell moves to it" do
    {:ok, view, _} = at(@path)

    render_click(view, "select", %{"cell" => "category_health"})

    assert_patched(view, "#{@path}/cell/category_health")
  end

  describe "the graph view — the shape a tree cannot show" do
    test "draws a node per cell and an edge per input" do
      {:ok, _view, html} = at("#{@path}?view=graph")

      assert html =~ "<svg"
      assert html =~ "rdd-gbox"
      assert html =~ "rdd-edge"
    end

    test "columns come from the graph's own depth, not a layout pass" do
      # `Insights.levels/1` is longest-path-from-a-leaf, which IS the layered
      # assignment — so there is no layout algorithm to get wrong
      {:ok, _view, html} = at("#{@path}?view=graph")

      # depth 0 at the left pad, depth 1 one column over
      assert html =~ ~s|x="16"|
      assert html =~ ~s|x="262"|
    end

    test "an operation is a DIAMOND between the boxes, not an implied arrow" do
      # four inputs meeting at a MeetingJoin is a join; drawing it as four
      # arrows into a box says only that they arrive
      {:ok, _view, html} = at("#{@path}?view=graph")

      assert html =~ "rdd-gop"
      assert html =~ "rotate(45"
    end

    test "and it is labelled with the operator" do
      # from `expenses`, because the diagram is SCOPED to the selected node and
      # the default root's subtree has no union in it. That scoping is the
      # point of the view: drawing the whole plan at once is what made this
      # unreadable at real graph sizes.
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

      assert html =~ "rdd-goplabel"
      assert Regex.match?(~r/rdd-goplabel">\s*union/, html)
    end

    test "the diagram is SCOPED to the selected node, not the whole plan" do
      # the defect this view shipped with: `council_portal` reaches three cells,
      # and the diagram drew all twelve in the fixture — every node in the plan,
      # on one canvas, whatever was selected.
      {:ok, _view, html} = at("#{@path}/cell/council_portal?view=graph")

      # scoped to the SVG: the PICKER lists every cell in the plan by design,
      # so matching the whole page would test the wrong control
      svg = svg_of(html)

      assert svg =~ "council_portal"
      assert svg =~ "minutes"

      refute svg =~ "all_verdicts", "not reachable from council_portal"
      refute svg =~ "category_health", "belongs to the other source's subtree"
    end

    test "an edge is drawn only when BOTH ends are on the canvas" do
      # a scoped view must not draw an edge to a node it does not contain: the
      # segment count is bounded by the arrivals INSIDE the subgraph.
      {:ok, _view, html} = at("#{@path}/cell/council_portal?view=graph")

      edges = Regex.scan(~r/class="rdd-edge\s*"/, html) |> length()

      # council_portal → minutes, → resolutions, each via its own diamond:
      # two edges in, two out, and nothing leaving the subgraph
      assert edges == 4
    end

    test "a leaf has no diamond — nothing derives it" do
      {:ok, _view, html} = at("#{@path}?view=graph")

      diamonds = Regex.scan(~r/rdd-gop\b/, html) |> length()
      boxes = Regex.scan(~r/rdd-gbox\b/, html) |> length()

      assert diamonds < boxes, "sources are boxes with nothing feeding them"
    end

    test "a converging node is drawn as a stacked card" do
      # `all_verdicts` is read by two nodes; the stack is the same glyph the
      # tree uses for a cell reached by several routes
      {:ok, _view, html} = at("#{@path}?view=graph")

      assert html =~ "rdd-gstack"
    end

    test "nodes are selectable from the diagram" do
      {:ok, view, _} = at("#{@path}?view=graph")

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health?view=graph")
    end

    test "the view survives navigation, like direction does" do
      {:ok, view, _} = at("#{@path}/cell/expenses?view=graph")

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health?view=graph")
    end

    test "and the tree is still the default" do
      {:ok, _view, html} = at(@path)

      refute html =~ "<svg"
    end
  end

  describe "collapse — a 7-deep graph is unreadable expanded" do
    test "rows below depth 1 start hidden" do
      {:ok, _view, html} = at(@path)

      # From `expenses`, which is 4 deep. The default root reaches only 2
      # levels, so nothing under it is deep enough to start collapsed — the old
      # flat markup hid rows across all seven source panels at once, which is
      # why this passed against any cell.
      #
      # The CHILDREN WRAPPER is what hides now: one element per subtree, rather
      # than a class on every descendant row.
      {:ok, _view, deep} = at("#{@path}/cell/expenses")

      assert Regex.match?(~r/class="[^"]*\brdd-children\b[^"]*\bhidden\b/, deep)
    end

    test "a collapsible row carries its child count" do
      # a collapsed row with no count looks like a leaf, which is the failure
      # mode of collapsing by default
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-ccount"
    end

    test "expand and collapse are client-side, with no server round-trip" do
      {:ok, _view, html} = at(@path)

      assert html =~ "expand all"
      assert html =~ "remove_class"
      refute html =~ ~s|phx-click="expand"|
    end
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

      assert html =~ ~s|phx-click="select"|
      assert html =~ ~s|phx-value-cell="council_portal"|
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
      # picked must have something above it, which a root never does — so a
      # children wrapper is present, and it is not a dead end.
      assert html =~ "rdd-children", "something is nested under something"
      refute markup(html) =~ "rdd-empty"
    end

    test "upstream renders EXPANDED, because it is a chain not a fan-out" do
      # rendered collapsed, upstream showed a root and two closed rows and read
      # as having no hierarchy at all — which is how it was reported. Downstream
      # collapsing is right (one source reaches twenty cells); upstream narrows,
      # and the answer is several levels up.
      {:ok, _view, up} = at("#{@path}/cell/verdict_audit?direction=upstream")
      {:ok, _view, down} = at("#{@path}/cell/expenses")

      refute markup(up) =~ ~s|rdd-children hidden|,
             "nothing upstream starts closed"

      assert markup(down) =~ ~s|rdd-children hidden|,
             "downstream still collapses below depth 1"
    end

    test "and a named sink shows its full depth" do
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit?direction=upstream&view=tree")

      # verdict_audit ← all_verdicts ← category_health/spend_rollup ← expenses
      assert html =~ "all_verdicts"
      assert html =~ "category_health"
      assert html =~ "expenses"
    end

    test "downstream still starts at a root" do
      {:ok, _view, html} = at(@path)

      # the default root is a source, and it has a tree rather than a dead end
      assert html =~ "rdd-row"
      refute markup(html) =~ "rdd-empty"
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

      assert html =~ "category_health"
      assert html =~ "expenses", "two levels up, so the tree really inverted"
    end

    test "and downstream is still the default" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "category_health", "what expenses feeds"
    end
  end

  defp count(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
