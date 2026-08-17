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

  alias Phoenix.LiveView.JS

  import ReactiveDagDashboard.Components

  alias ReactiveDag.Insights
  alias ReactiveDagDashboard.{Actions, LiveUpdates, NodeDetail, Tree}

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:base_path, "/")
     |> assign(:selected, nil)
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
     |> assign(:selected, params["cell_id"] || default_cell(socket.assigns, dir))
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

  def handle_event("direction", %{"to" => to}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket.assigns, direction: to))}
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

  defp assign_view(%{assigns: %{selected: nil}} = socket) do
    socket
    |> assign(:groups, Tree.groups(socket.assigns.plan, socket.assigns.direction))
    |> assign(:node, nil)
    |> assign(:detail, nil)
    |> assign(:routes, 0)
    |> assign(:bands, [])
    |> assign(:dead_end?, false)
  end

  defp assign_view(%{assigns: %{plan: plan, selected: id, direction: dir}} = socket) do
    tree = tree_for(plan, id, dir)

    socket
    # The picker's own order depends on direction — the ends that matter for
    # THIS question come first — so it is assigned here, where direction is
    # known, rather than in `load/1`, which runs before `handle_params` sets it.
    |> assign(:groups, Tree.groups(plan, dir))
    # NESTED, not flattened: the markup recurses so containment is real
    # structure rather than a computed margin. See Components.hierarchy/1.
    |> assign(:node, Tree.nested(plan, tree, dir))
    |> assign(:routes, Tree.path_count(tree))
    # The diagram's scope, from the same tree the expression uses. Whole-plan
    # levels drew every cell at once, which at real graph sizes is a tangle no
    # amount of styling rescues (u2i/reactive_dag_dashboard#28).
    |> assign(:bands, Tree.levels(plan, tree))
    |> assign(:detail, NodeDetail.build(plan, id, socket.assigns.controls))
    # a source has nothing above it and an output nothing below: one direction
    # of each is a single node with no tree, which renders as an empty panel
    # and reads as broken unless the page says which way to look
    |> assign(:dead_end?, not Tree.has_tree?(plan, id, dir))
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

  # With nothing named, start where a change enters — the question people
  # arrive with is almost always "what happened to X", and X came from a source.
  # Direction decides where to START. Upstream from a ROOT is one node with
  # nothing above it — which is what "no hierarchy under upstream, each item a
  # single entry" was: the default cell was always a root, so the upstream view
  # could only ever show a leaf.
  defp default_cell(%{plan: plan}, :upstream), do: plan |> Tree.sinks() |> List.first()
  defp default_cell(%{plan: plan}, _downstream), do: plan |> Tree.roots() |> List.first()

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
    cell = Keyword.get(overrides, :cell, assigns.selected)
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

      <nav class="rdd-tabs">
        <button class={["rdd-tab", @view == :tree && "on"]} phx-click="view" phx-value-to="tree">
          expression
        </button>
        <button class={["rdd-tab", @view == :graph && "on"]} phx-click="view" phx-value-to="graph">
          graph
        </button>
      </nav>

      <%!-- The picker. Downstream used to render one panel per source and
            upstream a single panel rooted at the selection, so switching
            targets was a different gesture in each direction — and upstream had
            none at all: clicking a node silently re-rooted the whole page.
            Half a real graph is neither source nor sink, and none of it could
            be a starting point. --%>
      <div class="rdd-bar">
        <span class="rdd-bar-lab">rooted at</span>

        <div class="rdd-picker">
          <button class="rdd-pick" phx-click={JS.toggle(to: "#rdd-menu")}>
            <%= @selected || "—" %> <span class="rdd-caret">▾</span>
          </button>

          <div id="rdd-menu" class="rdd-menu hidden" phx-click-away={JS.hide(to: "#rdd-menu")}>
            <div :for={{label, ids} <- @groups} class="rdd-menu-group">
              <div class="rdd-menu-head"><%= label %> <span><%= length(ids) %></span></div>
              <button
                :for={id <- ids}
                class={["rdd-menu-item", id == @selected && "on"]}
                phx-click={JS.hide(to: "#rdd-menu") |> JS.push("select")}
                phx-value-cell={id}
              >
                <%= id %>
              </button>
            </div>
          </div>
        </div>

        <div class="rdd-seg">
          <button
            class={["rdd-segbtn", @direction == :downstream && "on"]}
            phx-click="direction"
            phx-value-to="downstream"
            title="what a change to this reaches"
          >
            downstream
          </button>
          <button
            class={["rdd-segbtn", @direction == :upstream && "on"]}
            phx-click="direction"
            phx-value-to="upstream"
            title="what feeds this"
          >
            upstream
          </button>
        </div>

        <span :if={@view == :tree and not @dead_end?} class="rdd-bar-acts">
          <button
            type="button"
            class="rdd-btn rdd-ghost"
            phx-click={
              JS.remove_class("hidden", to: ".rdd-children")
              |> JS.add_class("rotate-90", to: ".rdd-chev")
            }
          >
            expand all
          </button>
          <button
            type="button"
            class="rdd-btn rdd-ghost"
            phx-click={
              JS.add_class("hidden", to: ".rdd-children")
              |> JS.remove_class("rotate-90", to: ".rdd-chev")
            }
          >
            collapse
          </button>
        </span>

        <span :if={not @dead_end?} class="rdd-routes">
          <%= @routes %> route<%= if @routes == 1, do: "", else: "s" %>
        </span>
      </div>

      <%!-- A source has nothing above it and an output nothing below. That is
            an answer, not an error, but an empty panel reads as broken — so say
            it, and offer the direction that does have something. --%>
      <div :if={@dead_end?} class="rdd-empty">
        <p>
          <strong><%= @selected %></strong>
          <%= if @direction == :upstream,
            do: "is a source — nothing in this graph feeds it.",
            else: "is an output — nothing in this graph reads it." %>
        </p>
        <button
          class="rdd-btn"
          phx-click="direction"
          phx-value-to={if @direction == :upstream, do: "downstream", else: "upstream"}
        >
          <%= if @direction == :upstream, do: "see what it reaches →", else: "← see what feeds it" %>
        </button>
      </div>

      <div :if={@view == :graph and not @dead_end?}>
        <.graph levels={@bands} status={@status} selected={@selected} plan={@plan} />
        <p class="rdd-cap">
          <%= if @direction == :upstream, do: "what feeds", else: "what a change to" %>
          <code><%= @selected %></code>
          <%= if @direction == :upstream, do: "", else: "reaches" %> — convergence drawn once
        </p>
      </div>

      <div :if={@view == :tree and not @dead_end? and @node}>
        <.hierarchy node={@node} status={@status} selected={@selected} />
      </div>

      <.detail detail={@detail} />
    </main>
    """
  end
end
