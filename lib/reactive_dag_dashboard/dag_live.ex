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

  import ReactiveDagDashboard.Components

  alias ReactiveDag.Insights
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
          {"scan of #{scope} queued — results appear as it drains", false}

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
  def handle_info({:drain_step, cell_id, _changed}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> LiveUpdates.mark_stale(cell_id)}
  end

  def handle_info(:flush_stale, socket) do
    {:noreply, LiveUpdates.refresh_stale(socket, socket.assigns.plan)}
  end

  def handle_info({:drain_done, _report}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> load() |> assign_view()}
  end

  def handle_info({:drain_failed, _reason}, socket) do
    {:noreply, LiveUpdates.seen_event(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> load() |> assign_view()}

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

      <div :if={@root} class="rdd-bar">
        <nav class="rdd-tabs">
          <button class={["rdd-tab", @view == :tree && "on"]} phx-click="view" phx-value-to="tree">
            expression
          </button>
          <button class={["rdd-tab", @view == :graph && "on"]} phx-click="view" phx-value-to="graph">
            graph
          </button>
        </nav>


        <span class="rdd-routes">
          <%= @routes %> route<%= if @routes == 1, do: "", else: "s" %>
        </span>
      </div>

      <p :if={is_nil(@root)} class="rdd-prompt">
        Pick <%= if @direction == :upstream, do: "an output", else: "a source" %> above.
      </p>

      <%!-- An isolated cell is in both lists and has a tree in neither. --%>
      <div :if={@root && @dead_end?} class="rdd-empty">
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
        <.hierarchy node={@node} status={@status} details={@details} />
      </div>
    </main>
    """
  end
end
