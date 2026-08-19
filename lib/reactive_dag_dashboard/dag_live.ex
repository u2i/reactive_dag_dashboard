defmodule ReactiveDagDashboard.DagLive do
  @moduledoc """
  The dashboard: one page, built around a node.

  It used to be three views and a drawer — an index laid out by depth, plus
  `/from/:id` and `/into/:id` for the two directions. Each answered a slice of
  the same question, and none of them answered it alone: you found a cell on the
  index, went to `/from` to see what it reached, then back to read what it held.

  So: one page. The sources at the top (what feeds this graph, and when), the
  hierarchy below (what a change reaches), and a panel for whichever node you
  picked — what it does, where its code is, what it holds, and what it recently
  did.

  The two directions become a toggle rather than two routes, because they are
  one question asked from either end and the answer belongs beside the node
  either way.

  ## What the panel is for

  A graph picture tells you the shape and nothing about the behaviour. The
  useful questions are *"what does this node actually do"* — answered by the
  module's own moduledoc, which is usually better than anything a UI could
  invent — and *"is it working"*, answered by its recent recomputes. A node that
  looks structurally fine and has not run in a week is the interesting case, and
  its shape says nothing about that.

  See `ReactiveDagDashboard.NodeDetail`.
  """
  use Phoenix.LiveView

  # How many drains the log shows. The retention itself is the library's
  # (`config :reactive_dag, insights_keep:`); this only bounds the render.
  @log_runs 25

  import ReactiveDagDashboard.Components

  alias ReactiveDag.Drain.Report
  alias ReactiveDag.Insights
  alias ReactiveDag.Source
  alias ReactiveDagDashboard.{Actions, LiveUpdates, NodeDetail, Tree}

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:base_path, "/")
     |> assign(:root, nil)
     |> assign(:direction, :downstream)
     |> assign(:message, nil)
     |> load()
     |> LiveUpdates.setup()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    dir = direction(params)

    {:noreply,
     socket
     |> assign(:base_path, base_path(uri, params["cell_id"]))
     |> assign(:direction, dir)
     |> assign(:view, view(params))
     # NOT defaulted. With no cell named the page shows the starting points for
     # this direction and waits — picking one is the first act, rather than the
     # page guessing a root and rendering a tree nobody asked for.
     |> assign(:root, params["cell_id"])
     |> assign_view()}
  end

  # ── the two things this page DOES ───────────────────────────────────────────

  @impl true
  def handle_event("select", %{"cell" => cell_id}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket.assigns, cell: cell_id))}
  end

  # Direction rides in the URL, not just assigns. It used to be set here and
  # nowhere else, so `handle_params` — which runs on every patch, including the
  # one `select` issues — read it back from params and reset it to downstream.
  # The toggle worked until you clicked anything.
  def handle_event("view", %{"to" => to}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket.assigns, view: to))}
  end

  # Changing direction CLEARS the root. The two directions start from different
  # ends — sources downstream, outputs upstream — so a root chosen for one is
  # usually a dead end in the other, and carrying it over answered a question
  # nobody asked: you picked `expenses` to see what it reaches, hit upstream,
  # and got "nothing feeds this". Direction is chosen first and the list of
  # starting points follows from it.
  def handle_event("direction", %{"to" => to}, socket) do
    # `base_path` keeps its trailing slash so `<base>cell/<id>` composes; strip
    # it here, since `/ops/dag/?direction=…` is an odd URL to put in a bar.
    root = String.replace_suffix(socket.assigns.base_path, "/", "")
    {:noreply, push_patch(socket, to: "#{root}?direction=#{to}")}
  end

  def handle_event("scan", %{"cell" => cell_id} = params, socket) do
    mode = Map.get(params, "mode", "default")

    # what was ASKED for, so a narrowed poll does not report as a whole crawl —
    # "scanned agenda_center (fiscal_year = FY25/26): 3 new" is the difference
    # between a fast targeted fetch and a suspiciously quick full one
    scope = Actions.describe_scan(cell_id, params)

    {message, reload?} =
      case Actions.enqueue_scan(cell_id, mode, params, socket.assigns) do
        :queued ->
          # "as it drains" was a promise the page could not keep: a poll that
          # finds nothing never drains, so nothing appeared and the button looked
          # broken. The scan events now arrive either way.
          {"scan of #{scope} queued — waiting for it to run", false}

        {:ran, %{unreachable: []} = result} ->
          {"scanned #{scope}: #{Actions.summarise(result)}#{Actions.across_leaves(result)}", true}

        # An outage is not a quiet success. A scan that could not look must not
        # render as a scan that found nothing.
        {:ran, %{unreachable: up} = result} ->
          {"scanned #{scope}: #{Actions.summarise(result)}, #{length(up)} upstream(s) " <>
             "unreachable — results are incomplete", true}

        :no_scanner ->
          {"#{cell_id} has no scanner", false}

        {:error, reason} ->
          {"scan failed: #{inspect(reason)}", false}
      end

    socket = assign(socket, :message, message)
    {:noreply, if(reload?, do: socket |> load() |> assign_view(), else: socket)}
  end

  def handle_event("reprocess", %{"cell" => cell_id} = params, socket) do
    args =
      %{"cell" => cell_id, "reason" => "dashboard"}
      |> Actions.put_where(params)
      |> Actions.put_plan(socket.assigns.plan_mfa)

    message =
      case Actions.run_reprocess(args, socket.assigns.plan, cell_id, params) do
        :queued -> "reprocess of #{Actions.describe(cell_id, params)} queued"
        {:ran, m} -> "reprocessed #{Actions.describe(cell_id, params)}: #{Actions.outcome(m)}"
        :nothing_selected -> "nothing to reprocess in #{Actions.describe(cell_id, params)}"
        {:error, reason} -> "reprocess failed: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:message, message) |> load() |> assign_view()}
  end

  # ── live updates ────────────────────────────────────────────────────────────

  @impl true
  # `changed` was discarded here. It is the number the trail shows — "ran, 12
  # changed" is the difference between a cell that did work and one the drain
  # merely visited and found settled.
  def handle_info({:drain_step, cell_id, changed}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_step(cell_id, length(List.wrap(changed)))
     |> LiveUpdates.mark_stale(cell_id)}
  end

  def handle_info(:flush_stale, socket) do
    {:noreply, LiveUpdates.refresh_stale(socket, socket.assigns.plan)}
  end

  def handle_info({:drain_done, _report}, socket) do
    {:noreply,
     socket |> LiveUpdates.seen_event() |> LiveUpdates.finish() |> load() |> assign_view()}
  end

  def handle_info({:drain_failed, _reason}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> LiveUpdates.finish()}
  end

  # ONE cell failed; the drain carried on. Marked on the trail rather than
  # announced as a drain failure — its keys are still dirty and the next drain
  # retries them, so "this did not run" is the honest reading, not "everything
  # broke".
  def handle_info({:cell_failed, cell_id, reason}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_step(cell_id, {:failed, reason})}
  end

  def handle_info(:clear_trail, socket), do: {:noreply, LiveUpdates.clear_trail(socket)}

  # ── the scan half ───────────────────────────────────────────────────────────
  #
  # A queued scan told the page "results appear as it drains" and then, if the
  # poll found nothing, produced no events at all: a no-op scan dirties nothing,
  # so no `:drain_step` ever arrives. The promise went unkept and the button
  # looked broken on exactly the runs where it worked perfectly.

  def handle_info({:scan_started, cell_id}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_scan(cell_id, :running)
     |> assign(:message, "scanning #{cell_id}…")}
  end

  # A scanner emits per unit of work, so this arrives hundreds of times in one
  # crawl. `record_scan/3` throttles it — see there for why dropping an
  # intermediate count is free and dropping an OUTCOME is not.
  def handle_info({:scan_progress, cell_id, done, total}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_scan(cell_id, {:progress, done, total})}
  end

  def handle_info({:scan_done, cell_id, result}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_scan(cell_id, result)
     |> assign(:message, scan_outcome(cell_id, result))
     |> load()
     |> assign_view()}
  end

  def handle_info({:scan_failed, cell_id, reason}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_scan(cell_id, :failed)
     |> assign(:message, "scan of #{cell_id} failed: #{inspect(reason)}")}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> load() |> assign_view()}

  # "nothing changed" is an ANSWER, not an absence — and distinct again from a
  # scan that could not see: an outage must never render as a clean empty result.
  #
  # What it COST is a separate axis from what it found, so it is appended rather
  # than folded into each clause: a poll that changed nothing can still have
  # spent real money classifying documents that turned out to be unchanged, and
  # "nothing changed" alone reads as "this was free".
  defp scan_outcome(cell_id, run),
    do: "scanned #{cell_id} — " <> Actions.summarise(run) <> incomplete(run) <> cost(run)

  # ONE renderer for both paths. An inline scan already went through
  # `Actions.summarise/1` and said "2 new, 1 updated, 1 withdrawn"; a queued one
  # came through here and said "3 keys changed", because the observer had
  # flattened the result before broadcasting it. Same scan, same data, worse
  # wording on the path people actually use.
  #
  # `ScanRun.complete?/1` rather than a local `unreachable: up when up != []`:
  # the honest-gap check is the library's, and it was written twice here.
  defp incomplete(run) do
    if ReactiveDag.ScanRun.complete?(run) do
      ""
    else
      ", #{length(run.unreachable)} upstream(s) unreachable, so results are incomplete"
    end
  end

  # Only what a scanner actually reported. A crawler that spends nothing says
  # nothing, rather than a reassuring "0 tok" on every plain fetch.
  #
  # `detail_total/2` takes the poll result whole — a scan and a drain answer
  # "what did this cost" through one fold rather than two that must agree.
  defp cost(result) do
    tokens = Source.detail_total(result, :tokens_in) + Source.detail_total(result, :tokens_out)
    calls = Source.detail_total(result, :llm_calls)
    hits = Source.detail_total(result, :cache_hits)

    parts =
      [
        if(tokens > 0, do: "#{tok(tokens)} tok"),
        if(calls > 0, do: "#{calls} call#{if calls == 1, do: "", else: "s"}"),
        # Worth saying even at zero tokens: a crawl over hundreds of documents
        # that spent nothing BECAUSE the cache held is the change detection
        # working, not a crawl that did nothing.
        if(hits > 0, do: "#{hits} cached")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "", else: " · " <> Enum.join(parts, ", ")
  end

  # One entry per RUN, newest first, with the roll-ups a log line wants.
  #
  # THE SINGLE ADAPTER. `Insights.recent/1` hands back `%ScanRun{}` entries and
  # everything the log renders is shaped here, so the template reads plain maps
  # and a library change lands in one function rather than throughout the
  # markup.
  #
  # `ScanRun.total/2` sums a cost key across BOTH phases — the poll's own spend
  # and every step's — because the bill for a scan is the pair, and reading only
  # the drain's half understates a crawl that classifies with a model.
  defp runs(plan) do
    for %{run: run, at: at, polled?: polled?} <- Insights.recent(@log_runs) do
      report = run.report

      %{
        at: at,
        # THE POLL. Zero/empty on a bare drain, where there was none — and
        # `polled?` is what says which, rather than inferring it from a nil cell.
        polled?: polled?,
        scanned: run.cell,
        # The WHOLE run: a scan's poll plus its drain. The drain's own share is
        # below, and the gap between them is the poll — usually the larger
        # number, and the reason a two-minute scan used to log as 6.1ms.
        duration_us: run.duration_us,
        drain_us: report && report.duration_us,
        poll_changed: length(run.changed),
        # A scan that could not LOOK must never read as a scan that found
        # nothing. Carried whole, so the log can name the upstreams.
        unreachable: run.unreachable,
        complete?: ReactiveDag.ScanRun.complete?(run),
        # THE DRAIN. Nil-safe throughout: a scan of an unscannable source
        # completes without draining, and rendering "0 passes" for a drain that
        # never happened would be reporting a fact about nothing.
        drained?: ReactiveDag.ScanRun.drained?(run),
        cells: (report && length(Report.cells(report))) || 0,
        passes: (report && report.passes) || 0,
        changed: (report && Report.changed_total(report)) || 0,
        tokens_in: ReactiveDag.ScanRun.total(run, :tokens_in),
        tokens_out: ReactiveDag.ScanRun.total(run, :tokens_out),
        # In AND out per model. The two directions are priced differently, but
        # one bar per model reads where two do not, and the question this
        # answers is "which model is driving spend" rather than "what was the
        # in/out split". That split stays on the step.
        tokens_by: tokens_by(run),
        llm_calls: ReactiveDag.ScanRun.total(run, :llm_calls),
        cache_hits: ReactiveDag.ScanRun.total(run, :cache_hits),
        # The cascade, as a TREE rather than a flat list — see `run_tree/2`.
        roots: run_tree(plan, report)
      }
    end
  end

  # Empty unless there are at least two models to tell apart: a breakdown of one
  # is the total restated, and the total is already on the row. Deciding it here
  # rather than in the template because `:if` alongside `:for` is evaluated per
  # item and cannot say "unless the whole set is trivial".
  #
  # Across both phases, like the total it breaks down — a poll and a drain
  # commonly use different models (a classifier and a summariser are chosen
  # separately), which is exactly when the breakdown earns its place.
  defp tokens_by(run) do
    by =
      Map.merge(
        ReactiveDag.ScanRun.by(run, :tokens_in),
        ReactiveDag.ScanRun.by(run, :tokens_out),
        fn _model, a, b -> a + b end
      )

    if map_size(by) > 1, do: by, else: %{}
  end

  # The run as a TREE, matching the downstream view's shape — because a run IS a
  # change breaking things, and the flat list made you reconstruct the cascade
  # from an "after X" suffix on every row.
  #
  # ## The tree is the report's own
  #
  # No graph walk is needed to build it: every step carries `triggered_by`, the
  # cell whose propagation dirtied it, which is the same parent edge
  # `Tree.downstream/2` follows. A step with `triggered_by: nil` was dirty when
  # the drain started — a poll marked it, or a human did — so those are the
  # roots, and a run may have several.
  #
  # ## How far down to draw: the run's own trace, plus ONE ring
  #
  # The point of the feature is the user's "except where there is no need to
  # run", so the three states a cell can be in have to look different:
  #
  #   * recomputed and CHANGED — did work, and propagated
  #   * recomputed and UNCHANGED — did work, and correctly stopped the cascade
  #   * NEVER REACHED — an upstream stopped, so this never ran
  #
  # The first two are steps. The third is absence, and absence is what a flat
  # list cannot say: a cell reporting 0 changed is *why* everything below it is
  # missing, and without showing that the log reads as a truncated list rather
  # than a completed cascade.
  #
  # Drawing the FULL downstream tree with un-run cells greyed would say it, and
  # costs too much: a drain touching 3 cells in a 33-cell graph would render 30
  # grey rows, burying the 3 that did work under the graph's static shape. The
  # log is a record of what happened, not a picture of the plan.
  #
  # So: the steps, plus exactly one ring of un-run children — the cells a
  # stopped cell would have dirtied had it changed. That is the boundary itself
  # and nothing beyond it, which is the whole of the information "it stopped
  # here" carries. What lies past the boundary did not not-run for its own
  # reasons; it did not run because of the boundary, and the boundary is on
  # screen. Anyone wanting the full downstream shape has the downstream view a
  # tab away, which is the right place for a question about the graph rather
  # than about this run.
  defp run_tree(_plan, nil), do: []

  defp run_tree(plan, %Report{steps: steps}) do
    # A cell recomputed more than once (a diamond re-dirtied on a later pass)
    # keeps its LAST step, matching `Report.causes/1` — the drain's own
    # bookkeeping — so the tree has one node per cell rather than a repeat whose
    # two occurrences disagree about what changed.
    by_cell = Map.new(steps, &{&1.cell, &1})
    ran = MapSet.new(steps, & &1.cell)

    children =
      steps
      |> Enum.reject(&is_nil(&1.triggered_by))
      |> Enum.group_by(& &1.triggered_by, & &1.cell)
      |> Map.new(fn {parent, kids} -> {parent, kids |> Enum.uniq()} end)

    steps
    |> Enum.filter(&is_nil(&1.triggered_by))
    |> Enum.map(& &1.cell)
    |> Enum.uniq()
    |> Enum.map(&step_node(plan, &1, by_cell, children, ran, MapSet.new()))
  end

  # One node per cell that ran, with its un-run ring appended.
  #
  # `seen` guards descent, not display: a malformed report naming a cycle of
  # triggers must not hang the page, on the same reasoning `Tree` gives for
  # refusing to descend into a cell already on the path.
  defp step_node(plan, cell, by_cell, children, ran, seen) do
    step = by_cell[cell]
    changed = length(step.changed)

    kids =
      if MapSet.member?(seen, cell) do
        []
      else
        seen = MapSet.put(seen, cell)

        children
        |> Map.get(cell, [])
        |> Enum.map(&step_node(plan, &1, by_cell, children, ran, seen))
      end

    %{
      id: cell,
      cell: plan.cells[cell],
      ran?: true,
      changed: changed,
      claimed: length(step.claimed),
      op: step[:op],
      duration_us: step.duration_us,
      meta: step[:meta] || %{},
      # The BOUNDARY. A cell that changed nothing stopped the cascade, and the
      # cells it would have dirtied are the shape of that stop. Only drawn for a
      # cell that actually stopped: a cell that changed something has its real
      # children above, and listing its parents again as "not reached" would
      # contradict them.
      #
      # Filtered against `ran` because a diamond's tip can be reached by the
      # OTHER branch — `all_verdicts` still runs when `category_health` stops,
      # because `spend_rollup` changed. Naming it "not reached" under the branch
      # that stopped would be false, and it is drawn under the branch that did
      # reach it.
      not_reached:
        if changed == 0 do
          plan.parents |> Map.get(cell, []) |> Enum.reject(&MapSet.member?(ran, &1)) |> Enum.sort()
        else
          []
        end,
      kids: kids
    }
  end

  # ── assembling what the page shows ──────────────────────────────────────────

  defp load(socket) do
    {mod, fun, args} = socket.assigns.plan_mfa
    plan = apply(mod, fun, args)
    controls = ReactiveDag.Source.controls(plan)

    socket
    |> assign(:plan, plan)
    |> assign(:controls, controls)
    |> assign(:sources, NodeDetail.sources(plan, controls))
    |> assign(:status, Map.new(Insights.summary(plan), &{&1.id, &1}))
    |> assign(:pending, MapSet.new(Insights.pending(plan)))
    # The drain log. Retained in ETS by `Insights.record/1`, so it is per-node
    # and does not survive a restart — which is the right trade for "what just
    # happened" and the wrong one for an audit trail. A host wanting the latter
    # stores reports where its runs already live; the library says so.
    |> assign(:runs, runs(plan))
  end

  defp assign_view(%{assigns: %{root: nil}} = socket) do
    socket
    |> assign(:starts, Tree.starting_points(socket.assigns.plan, socket.assigns.direction))
    |> assign(:details, %{})
    |> assign(:node, nil)
    |> assign(:routes, 0)
    |> assign(:bands, [])
    |> assign(:dead_end?, false)
  end

  defp assign_view(%{assigns: %{plan: plan, root: id, direction: dir}} = socket) do
    tree = tree_for(plan, id, dir)

    socket
    # The starting points depend on direction, so they are assigned here where
    # it is known rather than in `load/1`, which runs before `handle_params`.
    |> assign(:starts, Tree.starting_points(plan, dir))
    # Every node's detail, keyed by id — the tree renders it inline behind a
    # disclosure rather than the page holding one "selected" node. A row that
    # can show its own detail needs no selection to be the subject.
    |> assign(:details, details_for(plan, tree, socket.assigns.controls))
    # NESTED, not flattened: the markup recurses so containment is real
    # structure rather than a computed margin. See Components.hierarchy/1.
    |> assign(:node, Tree.nested(plan, tree))
    |> assign(:routes, Tree.path_count(tree))
    # The diagram's scope, from the same tree the expression uses. Whole-plan
    # levels drew every cell at once, which at real graph sizes is a tangle no
    # amount of styling rescues (u2i/reactive_dag_dashboard#28).
    |> assign(:bands, Tree.levels(plan, tree))
    # a source has nothing above it and an output nothing below: one direction
    # of each is a single node with no tree, which renders as an empty panel
    # and reads as broken unless the page says which way to look
    # An ISOLATED cell — no inputs and no consumers — is both a source and an
    # output, so it appears in either list and has a tree in neither. Rare, and
    # the honest rendering is to say so rather than draw one lonely card.
    |> assign(:dead_end?, not Tree.has_tree?(plan, id, dir))
  end

  # One detail per node ON SCREEN, not for the whole plan: the tree is scoped,
  # and building 33 of these to render 6 is work nobody sees.
  defp details_for(plan, tree, controls) do
    tree
    |> Tree.flatten()
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Map.new(&{&1, NodeDetail.build(plan, &1, controls)})
  end

  defp tree_for(plan, id, :upstream), do: Tree.upstream(plan, id)
  defp tree_for(plan, id, _downstream), do: Tree.downstream(plan, id)

  # `panels/1` and `rows_for/2` are gone. The page rendered one panel per SOURCE
  # downstream and one rooted at the selection upstream, which made switching
  # targets a different gesture in each direction — and upstream had no picker
  # at all, so clicking a node silently re-rooted the page and the node you
  # clicked vanished into the root position.
  #
  # One tree, one root, either direction, chosen from a picker over every cell.

  # There is deliberately no default root. The page shows the starting points
  # for the chosen direction and waits: guessing one rendered a tree nobody
  # asked for, and made the first thing on screen an arbitrary cell.

  defp direction(%{"direction" => "upstream"}), do: :upstream
  defp direction(_), do: :downstream

  # The tree answers "what does a change here reach" and repeats a cell per
  # route; the graph answers "what is the shape of the whole thing" and draws
  # convergence once. Two questions, two renderings of one expression.
  defp view(%{"view" => "graph"}), do: :graph
  defp view(%{"view" => "log"}), do: :log
  defp view(_), do: :tree

  # One place that builds a link, so a cell change cannot drop the direction and
  # a direction change cannot drop the cell.
  defp path_for(assigns, overrides) do
    cell = Keyword.get(overrides, :cell, assigns.root)
    dir = Keyword.get(overrides, :direction, to_string(assigns.direction))
    view = Keyword.get(overrides, :view, to_string(assigns.view))

    query =
      [{"direction", dir}, {"view", view}]
      |> Enum.reject(fn {k, v} ->
        (k == "direction" and v == "downstream") or (k == "view" and v == "tree")
      end)
      |> case do
        [] -> ""
        pairs -> "?" <> URI.encode_query(pairs)
      end

    "#{assigns.base_path}cell/#{cell}#{query}"
  end

  # The host picks the mount prefix, so links derive from the request URI.
  defp base_path(uri, cell_id) do
    suffix = if cell_id, do: "cell/#{cell_id}", else: ""

    (URI.parse(uri).path || "/")
    |> String.replace_suffix(suffix, "")
    |> then(&if String.ends_with?(&1, "/"), do: &1, else: &1 <> "/")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="rdd">
      <%!-- The styles travel WITH the page, so a host that supplies its own
            `root_layout:` — which the docs recommend, and which cascade does —
            still gets them. They used to live only in this library's own
            layout, so overriding it silently dropped every rule. --%>
      <.styles />

      <header class="rdd-head">
        <h1>reactive_dag</h1>
        <span class={["rdd-badge", (@live? && "rdd-b-ok") || "rdd-b-mute"]}>
          <%= if @live?, do: "live", else: "polling" %>
        </span>
      </header>

      <div :if={@message} class="rdd-alert"><%= @message %></div>

      <%!-- DIRECTION FIRST. It is the question being asked, and it decides
            which cells can even be a starting point: downstream begins where
            data enters, upstream at the table you are looking at. Choosing a
            node first and then flipping direction asked the page something
            about a cell that was usually a dead end in the other direction. --%>
      <div class="rdd-ask">
        <button
          class={["rdd-askbtn", @direction == :downstream && "on"]}
          phx-click="direction"
          phx-value-to="downstream"
        >
          <span class="rdd-askq">what a change breaks</span>
          <span class="rdd-askn">from a source, downstream</span>
        </button>
        <button
          class={["rdd-askbtn", @direction == :upstream && "on"]}
          phx-click="direction"
          phx-value-to="upstream"
        >
          <span class="rdd-askq">where this came from</span>
          <span class="rdd-askn">from an output, upstream</span>
        </button>
      </div>

      <%!-- The starting points for THAT question — sources downstream, outputs
            upstream. One list, no taxonomy: a derived cell is not somewhere you
            begin, and the opposite end is a dead end offered as a choice. The
            middle of the graph is reached by clicking a name in the tree. --%>
      <div class="rdd-starts">
        <button
          :for={id <- @starts}
          class={["rdd-start", id == @root && "on"]}
          phx-click="select"
          phx-value-cell={id}
        >
          <%= id %>
        </button>
      </div>

      <%!-- OUTSIDE the `@root` guard: `runs` is not node-scoped, so asking to see
            it must not require having first chosen a cell.

            And it sits apart from the pair, at the bar's other end. `expression`
            and `graph` are two views of the SELECTED NODE; `runs` is a list of
            drains. Side by side in one nav they read as three views of one
            thing — which is what the `@view != :log` guards below keep having to
            deny, suppressing the route count, the pick-a-node prompt and the
            dead-end notice whenever the log is showing.

            Those guards stay: they are about what the log DISPLACES, not about
            where its button sits. What moves is the claim the layout makes —
            two node views on the left, a list of runs at the far end. --%>
      <div class="rdd-bar">
        <nav class="rdd-tabs">
          <button class={["rdd-tab", @view == :tree && "on"]} phx-click="view" phx-value-to="tree">
            expression
          </button>
          <button class={["rdd-tab", @view == :graph && "on"]} phx-click="view" phx-value-to="graph">
            graph
          </button>
        </nav>

        <span :if={@root && @view != :log} class="rdd-routes">
          <%= @routes %> route<%= if @routes == 1, do: "", else: "s" %>
        </span>

        <button
          class={["rdd-tab", "rdd-tab-runs", @view == :log && "on"]}
          phx-click="view"
          phx-value-to="log"
        >
          runs
        </button>
      </div>

      <p :if={is_nil(@root) and @view != :log} class="rdd-prompt">
        Pick <%= if @direction == :upstream, do: "an output", else: "a source" %> above.
      </p>

      <.log :if={@view == :log} runs={@runs} />

      <%!-- An isolated cell is in both lists and has a tree in neither. --%>
      <div :if={@root && @dead_end? && @view != :log} class="rdd-empty">
        <p><strong><%= @root %></strong> is not connected to anything in this graph.</p>
      </div>

      <div :if={@root && @view == :graph && not @dead_end?}>
        <.graph levels={@bands} status={@status} selected={@root} plan={@plan} />
        <p class="rdd-cap">
          <%= if @direction == :upstream, do: "what feeds", else: "what a change to" %>
          <code><%= @root %></code>
          <%= if @direction == :upstream, do: "", else: "reaches" %> — convergence drawn once
        </p>
      </div>

      <div :if={@root && @view == :tree && @node && not @dead_end?}>
        <.hierarchy node={@node} status={@status} details={@details} activity={@activity} />
      </div>
    </main>
    """
  end
end
