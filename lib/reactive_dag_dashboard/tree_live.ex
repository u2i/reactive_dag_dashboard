defmodule ReactiveDagDashboard.TreeLive do
  @moduledoc """
  The two directional views: a graph fully exploded into every path.

  | route | question |
  |---|---|
  | `/from/:cell_id` | a change here goes **where**? |
  | `/into/:cell_id` | this table is fed by **what**? |

  Both render `ReactiveDagDashboard.Tree` in one of two shapes. The default is
  **collapsed** — one row per cell, banded by distance, each row naming every
  edge it arrives by — because following a source to where it lands is the
  common question. `?shape=paths` gives the **exploded** tree, a row per route,
  which is the shape for costing a change rather than tracking one. The index depth panel
  (`PageLive`) answers "what does the graph contain"; these answer "how does a
  change travel", which is the question you have when something is wrong.

  Each row carries the cell's live state from `ReactiveDag.Insights` (key count,
  status chips), so a path reads as *what will recompute* and *what it holds*
  at once — the two halves of "was this expensive, and is it right".
  """
  use Phoenix.LiveView

  alias ReactiveDag.Insights
  alias ReactiveDagDashboard.{Algebra, Tree}

  alias ReactiveDagDashboard.LiveUpdates

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:base_path, "/")
     |> load()
     |> LiveUpdates.setup()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    direction = socket.assigns.live_action
    id = params["cell_id"] || default_root(socket.assigns.plan, direction)

    {:noreply,
     socket
     |> assign(:direction, direction)
     |> assign(:selected, id)
     |> assign(:shape, shape(params))
     |> assign(:base_path, base_path(uri, direction, params["cell_id"]))
     |> assign_tree()}
  end

  # ── live updates ────────────────────────────────────────────────────────────
  # A step names the cell that moved, so only that cell is re-read. Steps are
  # accumulated and flushed together: a 40-cell drain should cost a few renders,
  # not forty.
  @impl true
  def handle_info({:drain_step, cell_id, _changed_keys}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> LiveUpdates.mark_stale(cell_id)}
  end

  def handle_info(:flush_stale, socket) do
    {:noreply, LiveUpdates.refresh_stale(socket, socket.assigns.plan)}
  end

  # the drain finished: the frontier is now empty, so `pending` moved too — and
  # that is graph-wide, not per-cell.
  def handle_info({:drain_done, _report}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> load() |> assign_tree()}
  end

  def handle_info({:drain_failed, _reason}, socket) do
    {:noreply, LiveUpdates.seen_event(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> load() |> assign_tree()}

  defp load(socket) do
    {mod, fun, args} = socket.assigns.plan_mfa
    plan = apply(mod, fun, args)

    socket
    |> assign(:plan, plan)
    |> assign(:status, Map.new(Insights.summary(plan), &{&1.id, &1}))
    |> assign(:roots, Tree.roots(plan))
    |> assign(:root_groups, Tree.roots_by_scanner(plan))
    |> assign(:sinks, Tree.sinks(plan))
  end

  defp assign_tree(%{assigns: %{selected: nil}} = socket),
    do:
      socket
      |> assign(:rows, [])
      |> assign(:levels, [])
      |> assign(:tree_rows, [])
      |> assign(:paths, 0)

  defp assign_tree(%{assigns: %{plan: plan, selected: id, direction: dir}} = socket) do
    tree = if dir == :upstream, do: Tree.upstream(plan, id), else: Tree.downstream(plan, id)

    socket
    |> assign(:rows, Tree.flatten(tree))
    |> assign(:levels, Tree.levels(plan, tree))
    |> assign(:tree_rows, Tree.hierarchy(plan, tree))
    |> assign(:paths, Tree.path_count(tree))
  end

  # Collapsed by default: following a source to where it lands is the common
  # question, and the exploded shape answers a different one (what does this
  # change COST) at the price of a row per route.
  defp shape(%{"shape" => "paths"}), do: :paths
  defp shape(%{"shape" => "cells"}), do: :cells
  defp shape(_), do: :tree

  # with no cell named, start somewhere useful rather than blank: the first
  # place a change enters (downstream) or the last place it lands (upstream).
  defp default_root(plan, :upstream), do: plan |> Tree.sinks() |> List.first()
  defp default_root(plan, _downstream), do: plan |> Tree.roots() |> List.first()

  # the host picks the mount prefix, so links are derived from the request URI
  # rather than assuming one. Strip this route's own suffix; keep the rest.
  defp base_path(uri, direction, cell_id) do
    segment = if direction == :upstream, do: "into", else: "from"
    suffix = if cell_id, do: "#{segment}/#{cell_id}", else: segment

    (URI.parse(uri).path || "/")
    |> String.replace_suffix(suffix, "")
    |> then(&if String.ends_with?(&1, "/"), do: &1, else: &1 <> "/")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="rdd">
      <nav class="rdd-tabs">
        <.link patch={String.trim_trailing(@base_path, "/") |> nonempty("/")}>graph</.link>
        <.link patch={"#{@base_path}from"} class={active(@direction, :downstream)}>
          where a change goes
        </.link>
        <span class={"rdd-live rdd-live-#{@live?}"} title={live_hint(@live?)}>
          <%= if @live?, do: "live", else: "polling" %>
        </span>
        <.link patch={"#{@base_path}into"} class={active(@direction, :upstream)}>
          what feeds this
        </.link>
      </nav>

      <h1><%= heading(@direction) %></h1>

      <section class="rdd-picker">
        <h2><%= picker_label(@direction) %></h2>

        <div :for={{origin, scanner, ids} <- picker_groups(@direction, @root_groups, @sinks)} class="rdd-group">
          <h3 :if={origin} class={group_class(scanner)}>
            <%= origin %>
            <span :if={scanner && length(ids) > 1} class="rdd-note">
              one crawl, <%= length(ids) %> leaves
            </span>
          </h3>

          <ul>
            <li :for={id <- ids} class="rdd-cell">
              <.link patch={"#{@base_path}#{segment(@direction)}/#{id}"} class={picked(id, @selected)}>
                <%= id %>
              </.link>
            </li>
          </ul>
        </div>
      </section>

      <p :if={@selected == nil} class="rdd-empty">
        This graph has no <%= picker_label(@direction) %>.
      </p>

      <section :if={@selected && @shape == :tree} class="rdd-hier">
        <h2>
          <%= @paths %> <%= if @paths == 1, do: "route", else: "routes" %>
          <span class="rdd-note">
            structure, with each cell expanded once —
            <.link patch={"#{@base_path}#{segment(@direction)}/#{@selected}?shape=cells"}>
              flat list by distance
            </.link>
          </span>
        </h2>

        <ol>
          <li :for={row <- @tree_rows} class={hier_class(row)} style={"--indent: #{row.depth}"}>
            <span class="rdd-branch" aria-hidden="true"><%= branch(row) %></span>

            <.link patch={"#{@base_path}#{segment(@direction)}/#{row.id}"}><%= row.id %></.link>

            <span :if={op_label(row)} class="rdd-op"><%= op_label(row) %></span>

            <span :if={input_role(@plan, @direction, row)} class="rdd-role">
              <%= input_role(@plan, @direction, row) %>
            </span>

            <span :if={op_detail(row)} class="rdd-detail"><%= op_detail(row) %></span>

            <span :if={row.routes > 1} class="rdd-badge rdd-converge" title={"also reached via #{Enum.join(row.arrivals -- [row.via], ", ")}"}>
              <%= row.routes %> routes in
            </span>

            <span :if={row.cyclic?} class="rdd-badge rdd-cyclic">cycle</span>

            <span class="rdd-count"><%= key_count(@status[row.id]) %></span>

            <span :for={{status, n} <- statuses(@status[row.id])} class="rdd-status">
              <%= status %>&nbsp;<%= n %>
            </span>
          </li>
        </ol>
      </section>

      <section :if={@selected && @shape == :cells} class="rdd-bands">
        <h2>
          <%= cell_total(@levels) %> cells over <%= @paths %>
          <%= if @paths == 1, do: "route", else: "routes" %>
          <span class="rdd-note">
            one row per cell —
            <.link patch={"#{@base_path}#{segment(@direction)}/#{@selected}"}>
              back to the hierarchy
            </.link>
          </span>
        </h2>

        <div :for={{distance, cells} <- @levels} class="rdd-band">
          <h3 class="rdd-band-label"><%= band_label(distance, @direction) %></h3>

          <ul>
            <li :for={row <- cells} class="rdd-cell">
              <.link patch={"#{@base_path}#{segment(@direction)}/#{row.id}"}><%= row.id %></.link>

              <span :if={row.cell && row.cell.leaf?} class="rdd-badge">leaf</span>

              <span :if={row.via != []} class="rdd-via">
                <%= via_label(@direction) %> <%= Enum.join(row.via, ", ") %>
              </span>

              <span :if={row.routes > 1} class="rdd-badge rdd-converge" title="reached by more than one route">
                <%= row.routes %> routes
              </span>

              <span class="rdd-count"><%= key_count(@status[row.id]) %></span>

              <span :for={{status, n} <- statuses(@status[row.id])} class="rdd-status">
                <%= status %>&nbsp;<%= n %>
              </span>
            </li>
          </ul>
        </div>
      </section>

      <section :if={@selected && @shape == :paths} class="rdd-tree">
        <h2>
          <%= @paths %> <%= if @paths == 1, do: "path", else: "paths" %>
          <span class="rdd-note">
            every route shown, so a shared cell repeats —
            <.link patch={"#{@base_path}#{segment(@direction)}/#{@selected}"}>
              collapse to one row per cell
            </.link>
          </span>
        </h2>

        <ol>
          <li
            :for={row <- @rows}
            class={row_class(row)}
            style={"--indent: #{row.depth}"}
          >
            <span class="rdd-rail" aria-hidden="true"></span>

            <.link patch={"#{@base_path}#{segment(@direction)}/#{row.id}"}><%= row.id %></.link>

            <span :if={row.via} class="rdd-via"><%= via_label(@direction) %> <%= row.via %></span>
            <span :if={row.cell && row.cell.leaf?} class="rdd-badge">leaf</span>
            <span :if={row.repeat?} class="rdd-badge rdd-repeat" title="already reached by another path">
              repeat
            </span>
            <span :if={row.cyclic?} class="rdd-badge rdd-cyclic">cycle</span>

            <span class="rdd-count"><%= key_count(@status[row.id]) %></span>

            <span :for={{status, n} <- statuses(@status[row.id])} class="rdd-status">
              <%= status %>&nbsp;<%= n %>
            </span>
          </li>
        </ol>
      </section>
    </main>
    """
  end

  # the mount root has no trailing slash — "/ops/dag/" and "/ops/dag" are the
  # same page to a browser but only one matches the route cleanly.
  # "nothing changed" and "I am not being told about changes" look identical on a
  # static page, so the mode is stated rather than left to be inferred.
  defp live_hint(true), do: "subscribed to drain telemetry — updates arrive as they happen"

  defp live_hint(false),
    do: "no drain events; polling. Call ReactiveDagDashboard.Observer.attach/1 to go live."

  defp nonempty("", fallback), do: fallback
  defp nonempty(path, _fallback), do: path

  # The algebra, read off the cell's own `reactive` block. A flat `inputs` list
  # makes every edge look alike, and they are not: a join's left and right are
  # not interchangeable, a union's inputs are alternatives. The operator IS the
  # relationship, so it belongs on the node.
  defp op_label(row), do: Algebra.label(row.cell)

  defp op_detail(row), do: Algebra.detail(row.cell)

  # The role is a property of the EDGE, declared by whichever end CONSUMES the
  # other. Going downstream this row consumes `via`; going upstream `via`
  # consumes this row. Asking the producer instead yields nothing silently — it
  # never declared the relationship.
  defp input_role(_plan, _dir, %{via: nil}), do: nil

  defp input_role(plan, :upstream, row),
    do: plan.cells[row.via] |> Algebra.roles() |> Map.get(row.id)

  defp input_role(plan, _downstream, row),
    do: plan.cells[row.id] |> Algebra.roles() |> Map.get(row.via)

  defp hier_class(%{cyclic?: true}), do: "rdd-row rdd-hier-row rdd-cyclic-row"
  defp hier_class(_), do: "rdd-row rdd-hier-row"

  defp branch(%{depth: 0}), do: ""
  defp branch(%{last?: true}), do: "└─"
  defp branch(_), do: "├─"

  defp cell_total(levels), do: levels |> Enum.map(fn {_d, rows} -> length(rows) end) |> Enum.sum()

  # A band is a distance, named for what that distance MEANS in this direction —
  # "2 hops" says nothing; "two recomputes away" is the thing you were tracking.
  defp band_label(0, :upstream), do: "this table"
  defp band_label(0, _), do: "the source"
  defp band_label(1, :upstream), do: "fed directly by"
  defp band_label(1, _), do: "recomputes directly"
  defp band_label(n, :upstream), do: "#{n} steps upstream"
  defp band_label(n, _), do: "#{n} recomputes away"

  defp heading(:upstream), do: "What feeds this"
  defp heading(_), do: "Where a change goes"

  # Downstream leaves group by the crawl that feeds them; sinks have no scanner,
  # so grouping them by one would invent a relationship. One shape either way,
  # so the markup does not fork.
  defp picker_groups(:upstream, _groups, sinks), do: [{nil, nil, sinks}]

  defp picker_groups(_downstream, groups, _sinks) do
    Enum.map(groups, fn
      {nil, nil, ids} -> {"no scanner declared", nil, ids}
      group -> group
    end)
  end

  defp group_class(nil), do: "rdd-group-label rdd-unscanned"
  defp group_class(_scanner), do: "rdd-group-label"

  defp picker_label(:upstream), do: "derived tables"
  defp picker_label(_), do: "leaves"

  defp segment(:upstream), do: "into"
  defp segment(_), do: "from"

  defp via_label(:upstream), do: "feeds"
  defp via_label(_), do: "via"

  defp active(direction, direction), do: "rdd-active"
  defp active(_, _), do: nil

  defp picked(id, id), do: "rdd-active"
  defp picked(_, _), do: nil

  # a repeat is dimmed rather than hidden: the path is real work, but the cell's
  # detail was already shown once and does not need reading twice.
  defp row_class(%{cyclic?: true}), do: "rdd-row rdd-cyclic-row"
  defp row_class(%{repeat?: true}), do: "rdd-row rdd-repeat-row"
  defp row_class(_), do: "rdd-row"

  defp key_count(nil), do: "?"
  defp key_count(%{key_count: 0}), do: "?"
  defp key_count(%{key_count: n}), do: n

  defp statuses(nil), do: []

  defp statuses(%{statuses: statuses}) do
    statuses
    |> Enum.reject(fn {status, _n} -> is_nil(status) end)
    |> Enum.sort()
  end
end
