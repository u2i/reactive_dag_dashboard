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

  # How many runs the log shows. The retention itself is the library's
  # (`config :reactive_dag, insights_keep:`); this only bounds the render.
  @log_runs 25

  import ReactiveDagDashboard.Components

  alias ReactiveDag.Report
  alias ReactiveDag.Insights
  alias ReactiveDag.Source
  alias ReactiveDagDashboard.{Actions, LiveUpdates, NodeDetail, Tree}

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     # Resolved ONCE at mount: the list is a host lookup (a table read), and a
     # switch that re-queried on every render would do it on every keystroke of
     # every other control.
     |> assign(:tenants, tenants(session["tenants_mfa"]))
     |> assign(:tenant, nil)
     |> assign(:base_path, "/")
     |> assign(:root, nil)
     |> assign(:direction, :downstream)
     |> assign(:message, nil)
     |> load()
     |> LiveUpdates.setup()}
  end

  # 50: enough to answer "what is in here" in one screen, small enough that the
  # LiveView diff stays cheap on a cell holding ten thousand rows.
  @rows_per_page 50

  @impl true
  def handle_params(params, uri, socket) do
    dir = direction(params)

    {:noreply,
     socket
     |> assign(:base_path, base_path(uri, params["cell_id"]))
     |> assign(:direction, dir)
     |> assign(:view, view(params))
     # In the URL like `direction`, so a link to a cell is a link to THAT
     # tenant's cell — and a copied URL shows the same graph to whoever opens it.
     |> put_tenant(tenant(params, socket.assigns.tenants))
     # NOT defaulted. With no cell named the page shows the starting points for
     # this direction and waits — picking one is the first act, rather than the
     # page guessing a root and rendering a tree nobody asked for.
     |> assign(:root, params["cell_id"])
     |> assign(:rows_status, params["status"])
     |> assign(:rows_status_label, status_label(params["status"]))
     |> assign(:rows_per_page, @rows_per_page)
     |> assign(:rows_offset, offset(params))
     |> assign_view()
     |> assign_rows(socket.assigns.live_action)}
  end

  # The rows behind a status count, loaded only on the route that shows them —
  # the tree does not need them, and a cell can hold ten thousand.
  #
  # `nil` is a REAL status (a node with no status column, or none set), so it
  # travels as `__nil__` rather than an absent param, which would mean "every
  # status".
  defp assign_rows(socket, :rows) do
    %{plan: plan, root: id, rows_status: status, rows_offset: offset} = socket.assigns

    case plan.cells[id] do
      nil ->
        assign(socket, :rows, %{rows: [], total: 0})

      cell ->
        wanted = if status in [nil, "__nil__"], do: [nil], else: [status]

        page =
          safe_page(cell, wanted,
            limit: @rows_per_page,
            offset: offset,
            tenant: plan.tenant
          )

        assign(socket, :rows, page)
    end
  end

  defp assign_rows(socket, _other), do: assign(socket, :rows, %{rows: [], total: 0})

  # A display path. A node whose resource is unreadable here — a policy, an
  # unmigrated table — must degrade to "cannot read" rather than crashing the
  # page that exists to explain the graph.
  defp safe_page(cell, statuses, opts) do
    ReactiveDag.Node.Rows.page_by_status(cell, statuses, opts)
  rescue
    _ -> %{rows: [], total: 0, unreadable?: true}
  end

  # `<base>cell/<id>` — back to the graph the row list came from.
  defp cell_path(base, id) do
    base = String.replace_suffix(base || "/", "/", "")
    "#{base}/cell/#{id}"
  end

  defp rows_page_path(base, id, status, offset) do
    base = String.replace_suffix(base || "/", "/", "")
    "#{base}/cell/#{id}/rows?status=#{status || "__nil__"}&offset=#{offset}"
  end

  # "showing 1–50 of 727". The TOTAL is the point: a page that says only
  # "50 rows" cannot tell you whether you have seen everything.
  defp showing(%{total: 0}, _offset, _per), do: "No rows in this status."

  defp showing(%{rows: rows, total: total}, offset, _per) do
    first = offset + 1
    last = offset + length(rows)
    "showing #{first}–#{last} of #{total}"
  end

  # One line per row, from whatever the record actually has. Which columns
  # matter is a question about the HOST's schema and this library cannot answer
  # it, so it shows the non-structural fields and lets the reader decide.
  #
  # Truncated per field rather than overall: a row whose first column is a
  # 4KB blob would otherwise push every other column off the line.
  defp record_summary(record) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Enum.reject(&drop_field?/1)
    |> Enum.sort_by(&field_rank/1)
    |> Enum.take(8)
    |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{truncate(v)}" end)
  end

  # Structural columns, and fields carrying nothing.
  #
  # An EMPTY map or list is not information — `aggregates=%{}` told a reader
  # only that the column exists. Two of them consumed a third of the row on
  # `meeting_shell` while `meeting_uuid` and `slug` were cut for space.
  defp drop_field?({k, v}) do
    k in [:__meta__, :__metadata__, :id, :inserted_at, :updated_at] or
      is_nil(v) or v == %{} or v == []
  end

  # IDENTITY FIRST, then everything else alphabetically.
  #
  # Sorting purely by name put `meeting_uuid` and `slug` at positions 7 and 9 on
  # `meeting_shell`, so a cap of six cut exactly the two columns a reader is
  # most likely to want — the canonical identity and the public URL — while
  # keeping two empty maps.
  #
  # `_uuid` and `_id` suffixes rather than a fixed list: this library does not
  # know a host's column names, but "ends in _uuid" is a reliable signal that a
  # column identifies something.
  @identity_last [:slug]

  defp field_rank({k, _v}) do
    name = Atom.to_string(k)

    rank =
      cond do
        String.ends_with?(name, "_uuid") -> 0
        k in @identity_last -> 1
        String.ends_with?(name, "_id") and k != :municipality_id -> 2
        true -> 3
      end

    {rank, name}
  end

  defp record_summary(_), do: ""

  defp truncate(v) do
    v |> inspect(limit: 3, printable_limit: 60) |> String.slice(0, 60)
  end

  # `nil` is a real status, not an absent one — a node with no status column, or
  # none set — so it reads as "unset" rather than as blank.
  defp status_label(s) when s in [nil, "__nil__"], do: "unset"
  defp status_label(s), do: s

  defp offset(params) do
    case Integer.parse(params["offset"] || "0") do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
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
  # Switching tenant CLEARS the cell. Cell ids repeat across tenants, so the same
  # id usually exists in both — and carrying it over would silently show a
  # different tenant's data under a name the reader already had on screen, which
  # is worse than starting from the picker. Direction survives: it is a question,
  # not a place.
  def handle_event("tenant", %{"to" => to}, socket) do
    root = String.replace_suffix(socket.assigns.base_path, "/", "")

    {:noreply,
     push_patch(socket,
       to: "#{root}?direction=#{socket.assigns.direction}&tenant=#{to}"
     )}
  end

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
          # finds nothing enqueues no cascade, so nothing appeared and the button
          # looked broken. The scan events now arrive either way.
          #
          # It is doubly right now: even a poll that DOES find something only
          # enqueues the propagation, so the recompute lands in a later job and
          # arrives as its own `:cascade_*` events rather than as part of this.
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
  # changed" is the difference between a cell that did work and one the cascade
  # merely visited and found settled.
  # A cell BEGAN. Recorded as activity so the row says what is running now, rather
  # than holding the last thing that finished — which after a poll is that poll's
  # final phase, and is why a working cascade read as a stall.
  def handle_info({:cell_running, cell_id, claimed}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_running(cell_id, claimed)}
  end

  # How far through a recompute is. Throttled like scan progress — an op emits per
  # unit, and dropping an intermediate count is free because the next supersedes it.
  def handle_info({:cell_progress, cell_id, done, total, label}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_cell_progress(cell_id, {done, total, label})}
  end

  def handle_info({:cascade_step, cell_id, changed}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_step(cell_id, length(List.wrap(changed)))
     |> LiveUpdates.mark_stale(cell_id)}
  end

  def handle_info(:flush_stale, socket) do
    {:noreply, LiveUpdates.refresh_stale(socket, socket.assigns.plan)}
  end

  def handle_info({:cascade_done, _report}, socket) do
    {:noreply,
     socket |> LiveUpdates.seen_event() |> LiveUpdates.finish() |> load() |> assign_view()}
  end

  def handle_info({:cascade_failed, _reason}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> LiveUpdates.finish()}
  end

  # ONE cell failed; the cascade carried on. Marked on the trail rather than
  # announced as a cascade failure — its savepoint rolled back and the branch
  # below it stopped, but everything else committed, so "this did not run" is
  # the honest reading, not "everything broke".
  def handle_info({:cell_failed, cell_id, reason}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_step(cell_id, {:failed, reason})}
  end

  # THE CASCADE STOPPED HERE — and a full `load/1` follows, because this is the
  # one event that changes what `Insights.pending/1` reports. A suspension is
  # committed as it happens, so the resource appears in `pending` immediately;
  # waiting for `:cascade_done` would leave the page showing a graph with no
  # stopped work in it while a branch was already parked.
  def handle_info({:suspended, cell_id, _waiting, reason, count}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_suspended(cell_id, reason, count)
     |> load()
     |> assign_view()}
  end

  # A job picked a stopping point back up. Nothing is cleared yet — the work is
  # only now beginning, and it may fail — so the mark stays until
  # `:resumption_done` says the suspensions were actually discharged.
  def handle_info({:resumed, _cell_id, _waiting, _n}, socket) do
    {:noreply, LiveUpdates.seen_event(socket)}
  end

  # …and cleared it. `load/1` again for the same reason as `:suspended`: the
  # point has left the suspension table, so `pending` shrank.
  def handle_info({:resumption_done, cell_id, _waiting, _discharged}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_resumed(cell_id)
     |> load()
     |> assign_view()}
  end

  def handle_info(:clear_trail, socket), do: {:noreply, LiveUpdates.clear_trail(socket)}

  # ── the scan half ───────────────────────────────────────────────────────────
  #
  # A queued scan told the page "results appear as it drains" and then, if the
  # poll found nothing, produced no events at all: a no-op scan enqueues nothing,
  # so no `:cascade_step` ever arrives. The promise went unkept and the button
  # looked broken on exactly the runs where it worked perfectly.
  #
  # The scan's own events are therefore the whole of what a scan reports. What
  # its findings go on to recompute is a separate job, and reaches the page as
  # `:cascade_*` messages that name no scan at all.

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
  def handle_info({:scan_progress, cell_id, done, total, label}, socket) do
    {:noreply,
     socket
     |> LiveUpdates.seen_event()
     |> LiveUpdates.record_scan(cell_id, {:progress, done, total, label})}
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
  # `detail_total/2` takes the poll result whole — a scan and a cascade answer
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
  # the recompute's half understates a crawl that classifies with a model.
  #
  # ## A scan and its propagation are now SEPARATE log entries
  #
  # They used to be one. A poll drained in the same job, so a `%ScanRun{}`
  # carried the report of the recompute it caused and one row said "polled, then
  # recomputed these cells". A poll now enqueues a cascade and returns, so
  # `run.report` is ALWAYS nil for anything the library produces and the cascade
  # records itself as its own entry when it runs.
  #
  # Everything below therefore still nil-guards `report`, but the guard now
  # covers the ordinary case rather than the exception: a host running a cascade
  # synchronously and recording the run itself is the only way a report arrives
  # attached to a poll. The recompute columns are simply absent on a scan row,
  # which is honest — that work had not happened yet when the scan finished.
  defp runs(plan) do
    # THIS GRAPH's runs. The buffer is process-wide and holds every tenant's, so
    # an unfiltered read put a scan of the Town's graph in the log the page was
    # showing for the Village — and `@log_runs` counted across all of them, so a
    # busy neighbour truncated this tenant's log to a handful of lines.
    #
    # `plan.tenant` is `"*"` for a host with one graph, which `recent/2`
    # normalises to "unfiltered" — so nothing changes for the single-graph case.
    for %{run: run, at: at, polled?: polled?} <-
          Insights.recent(@log_runs, tenant: plan.tenant) do
      report = run.report

      %{
        at: at,
        # THE POLL. Zero/empty on a bare cascade, where there was none — and
        # `polled?` is what says which, rather than inferring it from a nil cell.
        polled?: polled?,
        scanned: run.cell,
        # The run's own wall time. For a scan that is the poll, and nothing else:
        # the propagation it enqueues is a different job with a different
        # duration, and it logs itself.
        duration_us: run.duration_us,
        cascade_us: report && report.duration_us,
        poll_changed: length(run.changed),
        # A scan that could not LOOK must never read as a scan that found
        # nothing. Carried whole, so the log can name the upstreams.
        unreachable: run.unreachable,
        complete?: ReactiveDag.ScanRun.complete?(run),
        # THE RECOMPUTE. Nil-safe throughout, and now nil for every scan the
        # library produces — see the note above. `cascaded?` says whether this
        # row describes propagation at all, so the columns below are rendered
        # only when they mean something.
        #
        # `ScanRun.drained?/1` is deprecated and answers false unconditionally,
        # so this asks the report directly rather than routing a real question
        # through a function that can only give one answer.
        cascaded?: not is_nil(report),
        cells: (report && length(Report.cells(report))) || 0,
        # WHERE IT STOPPED. New, and the field with no predecessor: a cascade
        # that suspended finished cleanly with work parked, and nothing else on
        # this row distinguishes that from a cascade with nothing left to do.
        #
        # This replaces `passes` on the log line. `passes` still exists on the
        # report, but it counted drain-loop iterations over a queue and a
        # cascade is a single walk — it is 0 or 1 now and says nothing a reader
        # wants, whereas "stopped at 3 points" is the question a log gets read
        # for.
        suspended: (report && length(report.suspended)) || 0,
        suspensions: (report && report.suspended) || [],
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
  # Across both phases, like the total it breaks down — a poll and a cascade
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
  # `Tree.downstream/2` follows. A step with `triggered_by: nil` is an ORIGIN —
  # the cell the cascade was told had changed — so those are the roots, and a
  # run may have several.
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
  # costs too much: a cascade touching 3 cells in a 33-cell graph would render 30
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
    # A cell recomputed more than once keeps its LAST step, matching
    # `Report.causes/1` — the engine's own bookkeeping — so the tree has one node
    # per cell rather than a repeat whose two occurrences disagree about what
    # changed.
    #
    # Rarer than it was: a cascade merges everything queued for a cell before
    # running it, so a diamond's apex recomputes ONCE where the drain's queue
    # could only manage that by luck. The guard stays because a resumption's
    # onward cascade can still revisit a cell within one report.
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
          plan.parents
          |> Map.get(cell, [])
          |> Enum.reject(&MapSet.member?(ran, &1))
          |> Enum.sort()
        else
          []
        end,
      kids: kids
    }
  end

  # ── assembling what the page shows ──────────────────────────────────────────

  defp load(socket) do
    {mod, fun, args} = socket.assigns.plan_mfa

    # The chosen tenant is APPENDED to the declared args, so a host writes
    # `plan: {MyApp.Dag, :plan, []}` once and gets `plan/0` untenanted or
    # `plan/1` per tenant from the same declaration.
    args = if t = socket.assigns[:tenant], do: args ++ [t], else: args
    plan = apply(mod, fun, args)
    controls = ReactiveDag.Source.controls(plan)

    socket
    |> assign(:plan, plan)
    |> assign(:controls, controls)
    |> assign(:sources, NodeDetail.sources(plan, controls))
    |> assign(:status, Map.new(Insights.summary(plan), &{&1.id, &1}))
    # RESOURCES WITH WORK SUSPENDED — where cascades have stopped and are
    # waiting.
    #
    # What this means changed with the engine, and the old reading was the
    # opposite of actionable. Under the queue, `pending` listed cells a drain had
    # yet to reach: work in flight, clearing within seconds, and a name here was
    # noise. A suspension is work that has STOPPED and will not resume until a
    # job runs or a person acts — so a name appearing briefly is normal and a
    # name that stays is a question.
    #
    # That reversal is why it is now rendered at all. It was assigned and never
    # used, which was a defensible waste when the value cleared on its own; it
    # is not when the value means "this graph is not finishing its work".
    #
    # `Suspension.points/1` carries the counts and ages behind these — a count
    # climbing while `oldest` recedes is a point whose resumption keeps failing.
    # Not read here: this page reloads on every cascade event, and the points
    # query is per-tenant aggregate work that belongs behind a deliberate click
    # rather than on every step of every run.
    |> assign(:pending, Insights.pending(plan))
    # The run log. Retained in ETS by `Insights.record/1`, so it is per-node
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
    |> assign(:shared_graphs, [])
    |> assign(:routes, 0)
    |> assign(:bands, [])
    |> assign(:dead_end?, false)
  end

  defp assign_view(%{assigns: %{plan: plan, root: id, direction: dir}} = socket) do
    tree = tree_for(plan, id, dir)

    # `tree` (exploded) still drives `details_for/3`, `path_count/1` and
    # `levels/2`: those answer "what does a change COST", where a cell reached
    # by three routes really is three recomputes. `hoisted/3` answers "what is
    # the SHAPE", where drawing it three times is just noise.
    {hoisted_root, shared} = Tree.hoisted(plan, id, dir)

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
    |> assign(:node, Tree.nested(plan, hoisted_root))
    # One graph per shared cell, stacked below the main one. The exploded tree
    # drew a converging cell under every route that reaches it — 64 rows for 17
    # cells on a real graph, with one node drawn 18 times. Each cell is now
    # expanded once, and the routes to it are links.
    |> assign(
      :shared_graphs,
      Enum.map(shared, &%{&1 | tree: Tree.nested(plan, &1.tree, "g#{&1.id}")})
    )
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

  # Assign the tenant, and RELOAD when it changed.
  #
  # `mount/3` loads before `handle_params/3` runs, so the plan it built is the
  # default tenant's. Without the reload the switch would highlight the new
  # tenant while every panel below still showed the old one's graph — the two
  # disagreeing silently, which is why the nav renders the LOADED plan's tenant
  # rather than the assign.
  defp put_tenant(socket, tenant) do
    if socket.assigns[:tenant] == tenant do
      socket
    else
      socket |> Phoenix.Component.assign(:tenant, tenant) |> load()
    end
  end

  # The host's tenant list, normalised to `{id, label}`. `nil` when the host
  # named none — one graph, and the switch is not rendered at all.
  defp tenants(nil), do: []

  defp tenants({m, f, a}) do
    apply(m, f, a)
    |> Enum.map(fn
      {id, label} -> {to_string(id), to_string(label)}
      id -> {to_string(id), to_string(id)}
    end)
  end

  # The tenant from the URL, but only if the host actually declares it. An
  # unknown id falls back to the first rather than being passed through: it would
  # otherwise reach the host's plan builder, which has no reason to expect it —
  # and a typo'd URL should show a graph, not raise.
  defp tenant(_params, []), do: nil

  defp tenant(%{"tenant" => id}, tenants) do
    if Enum.any?(tenants, fn {t, _} -> t == id end), do: id, else: default_tenant(tenants)
  end

  defp tenant(_params, tenants), do: default_tenant(tenants)

  defp default_tenant([{id, _} | _]), do: id
  defp default_tenant(_), do: nil

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

    tenant = Keyword.get(overrides, :tenant, assigns[:tenant])

    query =
      [{"direction", dir}, {"view", view}, {"tenant", tenant}]
      |> Enum.reject(fn {k, v} ->
        is_nil(v) or (k == "direction" and v == "downstream") or
          (k == "view" and v == "tree")
      end)
      |> case do
        [] -> ""
        pairs -> "?" <> URI.encode_query(pairs)
      end

    # NO cell segment when nothing is selected. `cell/` with an empty id is not a
    # route, so `push_patch` raised — which is how the `runs` button broke when
    # clicked before picking a cell, the one view that is deliberately reachable
    # without one.
    segment = if cell in [nil, ""], do: "", else: "cell/#{cell}"

    "#{assigns.base_path}#{segment}#{query}"
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

      <%!-- `runs` lives HERE, in the page header, not down in the view bar.

            The three rows below are a funnel: which question (`rdd-ask`), which
            cell (`rdd-starts`), which view of it (`rdd-bar`). Each narrows the
            one above. `runs` answers none of those — it is a list of runs, a
            different destination — so anywhere inside the funnel reads as a
            further narrowing, and it read that way at the end of the third row
            just as it did in the middle of it. Being a sibling of the title is
            the honest position: page, not node. --%>
      <header class="rdd-head">
        <h1>reactive_dag</h1>
        <span class={["rdd-badge", (@live? && "rdd-b-ok") || "rdd-b-mute"]}>
          <%= if @live?, do: "live", else: "polling" %>
        </span>

        <button
          class={["rdd-tab", "rdd-tab-runs", @view == :log && "on"]}
          phx-click="view"
          phx-value-to="log"
        >
          runs
        </button>
      </header>

      <%!-- TENANT FIRST, above everything. The page below is a funnel — which
            question, which cell, which view — and a tenant is not a narrowing of
            any of that: it chooses WHICH GRAPH the funnel is about. Rendering it
            inside the funnel would read as a fourth filter on one graph, which
            is exactly what it is not. --%>
      <%!-- `data-tenant` is the LOADED plan's tenant, not the button state. They
            can disagree — a switch that highlights `village` while `load/1`
            still holds the borough's plan is the failure worth catching, and it
            is invisible if the page only ever renders what was clicked. --%>
      <nav :if={@tenants != []} class="rdd-tenants" data-tenant={@plan.tenant}>
        <span class="rdd-tenants-label">graph</span>
        <button
          :for={{id, label} <- @tenants}
          class={["rdd-tenant", @tenant == id && "on"]}
          phx-click="tenant"
          phx-value-to={id}
        >
          <%= label %>
        </button>
      </nav>

      <div :if={@message} class="rdd-alert"><%= @message %></div>

      <%!-- WHERE THIS GRAPH HAS STOPPED. Above the funnel, like the tenant
            switch, and for the same reason: it is a fact about the whole graph
            rather than a narrowing of it, and it is the one thing on this page
            a reader needs to see without having chosen a node first.

            Rendered as a standing banner rather than a badge on a row because
            a suspension is not a property of the node you happen to be looking
            at — the whole point is that you are NOT looking at it, and the
            branch below it has been quietly parked while everything on screen
            looks healthy.

            It is deliberately not an error. A suspension is the engine doing
            what the node declared: expensive work does not hold a transaction
            open, and work needing a person waits for one. What makes it worth
            saying is duration, which this cannot show — so it names the
            resources and leaves the judgement to the reader, who knows whether
            `meeting_events` waiting is this minute's normal or this week's
            problem. --%>
      <div :if={@pending != []} class="rdd-waiting">
        <span class="rdd-waiting-label">waiting</span>
        <span class="rdd-waiting-body">
          work is suspended at
          <code :for={name <- @pending} class="rdd-waiting-name"><%= name %></code>
          — a cascade reached each of these and stopped. It resumes when a job
          runs or a person acts, not on its own.
        </span>
      </div>

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

      <%!-- Two views of the SELECTED NODE. `runs` used to sit here too and does
            not belong: see the header. The `@view != :log` guards below stay
            regardless — they are about what the runs list DISPLACES on the page,
            not about where its button lives. --%>
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
      </div>

      <p :if={is_nil(@root) and @view != :log} class="rdd-prompt">
        Pick <%= if @direction == :upstream, do: "an output", else: "a source" %> above.
      </p>

      <.log
        :if={@view == :log}
        runs={@runs}
        activity={@activity}
        cascading?={@cascading?}
      />

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

      <%!-- THE ROWS behind a status count. Its own route, so it is linkable and
            so ten thousand rows get a page rather than a drawer — but the same
            LiveView, because the plan, the tenant and the counts are already
            here and a separate view would rebuild all three to show a list. --%>
      <section :if={@live_action == :rows} class="rdd-rows">
        <div class="rdd-rows-head">
          <h2>
            <code><%= @root %></code>
            <span class="rdd-rows-status"><%= @rows_status_label %></span>
          </h2>
          <.link navigate={cell_path(@base_path, @root)} class="rdd-rows-back">
            ← back to the graph
          </.link>
        </div>

        <p :if={@rows[:unreadable?]} class="rdd-rows-note">
          Could not read this node's rows. A policy, an unmigrated table, or a
          tenanted resource read without a tenant — the graph above is still
          correct.
        </p>

        <p :if={!@rows[:unreadable?]} class="rdd-rows-note">
          <%= showing(@rows, @rows_offset, @rows_per_page) %>
        </p>

        <table :if={@rows.rows != []} class="rdd-rows-table">
          <thead>
            <tr>
              <th>key</th>
              <th>status</th>
              <th>row</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @rows.rows}>
              <td class="rdd-rows-key"><%= r.key %></td>
              <td><%= r.status || "—" %></td>
              <%!-- The record, not a chosen subset. Which columns matter is a
                    question about the HOST's schema, and this library cannot
                    know the answer — so it shows what is there and lets the
                    reader decide. --%>
              <td class="rdd-rows-record"><%= record_summary(r.record) %></td>
            </tr>
          </tbody>
        </table>

        <div :if={@rows.total > @rows_per_page} class="rdd-rows-pager">
          <.link
            :if={@rows_offset > 0}
            navigate={rows_page_path(@base_path, @root, @rows_status, @rows_offset - @rows_per_page)}
            class="rdd-mini"
          >
            ← previous
          </.link>
          <.link
            :if={@rows_offset + @rows_per_page < @rows.total}
            navigate={rows_page_path(@base_path, @root, @rows_status, @rows_offset + @rows_per_page)}
            class="rdd-mini"
          >
            next →
          </.link>
        </div>
      </section>

      <div :if={@live_action != :rows && @root && @view == :tree && @node && not @dead_end?}>
        <.hierarchy
          node={@node}
          status={@status}
          details={@details}
          activity={@activity}
          base_path={@base_path}
        />

        <%!-- One graph per shared cell, stacked. A cell reached by several
              routes is drawn ONCE, here, and every route to it carries a link
              down to this anchor. The alternative — expanding it under each
              route — put 64 rows on the page for 17 cells. --%>
        <section
          :for={g <- @shared_graphs}
          id={"graph-#{g.id}"}
          class="rdd-shared-graph"
        >
          <div class="rdd-shared-head">
            <h3>
              <code><%= g.id %></code>
              <%!-- The route count belongs HERE now. It used to sit on the node
                    box as `× N routes`, and the compact reference that replaced
                    that box has no room for it — but it is the answer to "what
                    does a change cost", so it moves to the one place the cell is
                    drawn in full rather than being dropped. --%>
              <span :if={length(g.referenced_by) > 1} class="rdd-shared-routes">
                × <%= length(g.referenced_by) %> routes
              </span>
            </h3>
            <%!-- The backlink. A link that goes one way leaves you scrolling
                  to find who wanted this. --%>
            <p class="rdd-shared-refs">
              reached from
              <%= for {{ref, at}, i} <- Enum.with_index(g.referenced_by) do %><%= if i > 0, do: ", " %><a href={"#node-#{at}"}><code><%= ref %></code></a><% end %>
            </p>
          </div>

          <.hierarchy
            node={g.tree}
            status={@status}
            details={@details}
            activity={@activity}
            base_path={@base_path}
          />
        </section>
      </div>
    </main>
    """
  end
end
