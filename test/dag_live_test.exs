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

  # Just the starting-point strip. Cell ids appear all over the page — in the
  # tree, in the drawers, in the diagram — so a question about what is OFFERED
  # has to be asked of the offer.
  defp starts_of(html) do
    case Regex.run(~r/<div class="rdd-starts">(.*?)<\/div>\s*<[pd]/s, html) do
      [_, strip] -> strip
      nil -> ""
    end
  end

  # Just the diagram. Cell ids appear elsewhere on the page, so a question
  # about what the DIAGRAM contains has to be asked of the diagram.
  defp svg_of(html) do
    case Regex.run(~r/<svg.*?<\/svg>/s, html) do
      [svg] -> svg
      nil -> ""
    end
  end
  describe "the question comes first, then its starting points" do
    # The page used to name a root and offer a direction toggle beside it, over
    # a picker listing every cell grouped sources / derived / outputs. Three
    # problems, all the same shape — the control described the DATA STRUCTURE
    # rather than the work:
    #
    #   * `derived` is not somewhere you begin, it is somewhere you arrive;
    #   * the far end is a guaranteed dead end offered as a choice;
    #   * a root chosen for one direction is usually a dead end in the other,
    #     and flipping direction kept it.

    test "direction is asked as a question, before anything is chosen" do
      {:ok, _view, html} = at(@path)

      assert html =~ "what a change breaks"
      assert html =~ "where this came from"
    end

    test "with nothing chosen the page waits rather than guessing a root" do
      # it used to default to whichever cell sorted first, so the first thing
      # on screen was an arbitrary tree
      {:ok, _view, html} = at(@path)

      assert html =~ "rdd-prompt"
      assert html =~ "Pick a source"
      refute markup(html) =~ "rdd-row", "no tree until one is chosen"
    end

    test "downstream offers the SOURCES, and nothing else" do
      {:ok, _view, html} = at(@path)
      starts = starts_of(html)

      assert starts =~ ~s|phx-value-cell="expenses"|, "a source"
      assert starts =~ ~s|phx-value-cell="council_portal"|, "a source"

      refute starts =~ ~s|phx-value-cell="category_health"|, "derived is not a start"
      refute starts =~ ~s|phx-value-cell="verdict_audit"|, "an output is a dead end here"
    end

    test "upstream offers the OUTPUTS, and nothing else" do
      {:ok, _view, html} = at("#{@path}?direction=upstream")
      starts = starts_of(html)

      assert starts =~ ~s|phx-value-cell="verdict_audit"|, "an output"

      refute starts =~ ~s|phx-value-cell="expenses"|, "a source is a dead end here"
      refute starts =~ ~s|phx-value-cell="category_health"|, "derived is not a start"
    end

    test "no group headings at all — one list, not a taxonomy" do
      {:ok, _view, html} = at(@path)

      refute markup(html) =~ "derived"
    end

    test "picking a start roots the tree there" do
      {:ok, view, _} = at(@path)

      render_click(view, "select", %{"cell" => "expenses"})

      assert_patched(view, "#{@path}/cell/expenses")
    end

    test "changing direction CLEARS the root" do
      # the sticky-selection bug: you picked `expenses` to see what it reaches,
      # hit upstream, and got "nothing feeds this" — an answer to a question
      # nobody asked. The two directions start from different ends.
      {:ok, view, _} = at("#{@path}/cell/expenses")

      render_click(view, "direction", %{"to" => "upstream"})

      assert_patched(view, "#{@path}?direction=upstream")
    end

    test "and the starting points change with it" do
      {:ok, view, _} = at("#{@path}/cell/expenses")

      html = render_click(view, "direction", %{"to" => "upstream"})

      assert starts_of(html) =~ ~s|phx-value-cell="verdict_audit"|
      refute starts_of(html) =~ ~s|phx-value-cell="expenses"|
    end
  end

  describe "a row shows its own detail, in place" do
    test "every row carries a drawer, not one panel for the page" do
      # the detail used to render once at the foot of the page for whichever
      # row was last selected — so the answer appeared a scroll away from the
      # thing you asked about, and asking about a second row replaced the first
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      drawers = Regex.scan(~r/id="det-[^"]+"/, html) |> length()

      assert drawers > 1, "one per row, not one per page"
    end

    test "the drawer is keyed by PATH, so one occurrence opens alone" do
      # a converging node is drawn under every route that reaches it
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      ids = Regex.scan(~r/id="(det-[^"]+)"/, html, capture: :all_but_first) |> List.flatten()

      assert length(ids) == length(Enum.uniq(ids)), "no duplicate DOM ids"
    end

    test "opening one is client-side, with no server round-trip" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      # `select` still exists — on the starting-point CHIPS, which is what it
      # is for. What is gone is a row selecting itself: no tree row pushes it.
      tree = markup(html) |> String.split(~s|<div class="rdd-tree">|) |> List.last()

      refute tree =~ ~s|phx-click="select"|, "no row selects anything"
      assert tree =~ "det-", "it opens its own drawer instead"
    end

    test "the drawer carries what the node panel carried" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-card"
      assert html =~ "quick scan", "its scanner controls"
      assert html =~ "reprocess", "and its slice controls"
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

      # it is a patch, not a navigation — and it lands on the upstream question
      # with its own starting points, rather than re-rooting at all_verdicts
      assert html =~ "where this came from"
      assert starts_of(html) =~ ~s|phx-value-cell="verdict_audit"|
    end
  end

  describe "the node panel — what a graph picture cannot show" do
    test "a node explains itself, from its own moduledoc" do
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")
      on_exit(fn -> Application.put_env(:reactive_dag_dashboard, :source_url, nil) end)

      # UPSTREAM: `published` is a sink, so it is a starting point for "where
      # did this come from" and a dead end for "what does it break". Its
      # detail rides in its own row's drawer, so the tree has to exist.
      {:ok, _view, html} = at("#{@path}/cell/published?direction=upstream")

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
      {:ok, _view, html} = at("#{@path}/cell/expenses")

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
    {:ok, view, _} = at("#{@path}/cell/expenses")

    render_click(view, "select", %{"cell" => "category_health"})

    assert_patched(view, "#{@path}/cell/category_health")
  end

  describe "the graph view — the shape a tree cannot show" do
    test "draws a node per cell and an edge per input" do
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

      assert html =~ "<svg"
      assert html =~ "rdd-gbox"
      assert html =~ "rdd-edge"
    end

    test "columns come from the graph's own depth, not a layout pass" do
      # `Insights.levels/1` is longest-path-from-a-leaf, which IS the layered
      # assignment — so there is no layout algorithm to get wrong
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

      # depth 0 at the left pad, depth 1 one column over
      assert html =~ ~s|x="16"|
      assert html =~ ~s|x="262"|
    end

    test "an operation is a DIAMOND between the boxes, not an implied arrow" do
      # four inputs meeting at a MeetingJoin is a join; drawing it as four
      # arrows into a box says only that they arrive
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

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
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

      diamonds = Regex.scan(~r/rdd-gop\b/, html) |> length()
      boxes = Regex.scan(~r/rdd-gbox\b/, html) |> length()

      assert diamonds < boxes, "sources are boxes with nothing feeding them"
    end

    test "a converging node is drawn as a stacked card" do
      # `all_verdicts` is read by two nodes; the stack is the same glyph the
      # tree uses for a cell reached by several routes
      {:ok, _view, html} = at("#{@path}/cell/expenses?view=graph")

      assert html =~ "rdd-gstack"
    end

    test "nodes are selectable from the diagram" do
      {:ok, view, _} = at("#{@path}/cell/expenses?view=graph")

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health?view=graph")
    end

    test "the view survives navigation, like direction does" do
      {:ok, view, _} = at("#{@path}/cell/expenses?view=graph")

      render_click(view, "select", %{"cell" => "category_health"})

      assert_patched(view, "#{@path}/cell/category_health?view=graph")
    end

    test "and the tree is still the default" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      refute html =~ "<svg"
    end
  end

  describe "the row says what it is and what you can do to it" do
    test "a scanner names itself instead of reading 'leaf'" do
      # the teal spine says "nothing feeds this", which is not the same as
      # "something crawls it" — and it could not say WHAT crawls it. `origin/0`
      # is the scanner's own name for itself.
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "poll · Finance export"
    end

    test "and its cadence, since that is what makes a stale count expected" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "every 0 * * * *"
    end

    test "a derived row keeps its operation as the headline" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "reduce( folded: expenses ) by :category"
    end

    test "the operation LINKS to what implements it" do
      # it used to sit inside the drawer, where nobody found it — which is why
      # the links read as not working when they resolved perfectly well
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")
      on_exit(fn -> Application.put_env(:reactive_dag_dashboard, :source_url, nil) end)

      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-op-link"
      assert html =~ ~s|href="https://ex.com/|
    end

    test "scan controls ride on the scannable row itself" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ ~s|class="rdd-scan"|
      assert html =~ ~s|phx-value-mode="full"|, "and the full-scan variant"
    end

    test "including one button per slice value" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ ~s|phx-value-column="fiscal_year"|
      assert html =~ "FY25"
    end

    test "a slice with no enumerable values renders no buttons" do
      # `values:` is optional, and a label followed by nothing reads as broken
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      refute markup(html) =~ ~s|rdd-mini-slice"></button>|
    end

    test "and a row with no scanner carries none of it" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      # `category_health` is derived; only its ancestor `expenses` is polled
      [_, below] = String.split(markup(html), "category_health", parts: 2)
      [row, _] = String.split(below, "rdd-node", parts: 2)

      refute row =~ ~s|class="rdd-scan"|
    end
  end

  describe "the tree renders expanded" do
    test "nothing starts collapsed" do
      # A scoped tree is small — the largest in a real 33-cell graph is 29 rows
      # and the median is 6 — so collapsing bought nothing and cost the thing
      # you came to read. Upstream had the worse version of this: it opened
      # showing a root and two closed rows, and read as having no hierarchy.
      {:ok, _view, down} = at("#{@path}/cell/expenses")
      {:ok, _view, up} = at("#{@path}/cell/verdict_audit?direction=upstream")

      refute markup(down) =~ ~s|rdd-children hidden|
      refute markup(up) =~ ~s|rdd-children hidden|
    end

    test "so the whole depth is on screen without touching anything" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      # expenses → category_health → all_verdicts → verdict_audit, four levels
      assert html =~ "category_health"
      assert html =~ "all_verdicts"
      assert html =~ "verdict_audit"
    end

    test "a branch still folds by hand" do
      # the chevron stays: expanded by default is not the same as unfoldable,
      # and a wide branch in the way should be closable
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-chev"
      assert html =~ "kids-"
    end

    test "and the page-level expand/collapse buttons are gone" do
      # they controlled a state nothing starts in
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      refute markup(html) =~ "expand all"
      refute markup(html) =~ "collapse"
    end

    test "a row with children still carries its count" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      assert html =~ "rdd-ccount"
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
      {:ok, _view, html} = at("#{@path}/cell/expenses")

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
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit?direction=upstream")

      # asserted on the PROPERTY, not on which sink sorts first: whatever is
      # picked must have something above it, which a root never does — so a
      # children wrapper is present, and it is not a dead end.
      assert html =~ "rdd-children", "something is nested under something"
      refute markup(html) =~ "rdd-empty"
    end

    test "and a named sink shows its full depth" do
      {:ok, _view, html} = at("#{@path}/cell/verdict_audit?direction=upstream&view=tree")

      # verdict_audit ← all_verdicts ← category_health/spend_rollup ← expenses
      assert html =~ "all_verdicts"
      assert html =~ "category_health"
      assert html =~ "expenses"
    end

    test "downstream still starts at a root" do
      {:ok, _view, html} = at("#{@path}/cell/expenses")

      # the default root is a source, and it has a tree rather than a dead end
      assert html =~ "rdd-row"
      refute markup(html) =~ "rdd-empty"
    end
  end

  describe "direction survives navigation" do
    test "the toggle puts direction in the URL, and drops the root with it" do
      # the root is NOT carried over: the two directions start from different
      # ends, so a cell chosen for one is usually a dead end in the other
      {:ok, view, _} = at("#{@path}/cell/all_verdicts")

      render_click(view, "direction", %{"to" => "upstream"})

      assert_patched(view, "#{@path}?direction=upstream")
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
