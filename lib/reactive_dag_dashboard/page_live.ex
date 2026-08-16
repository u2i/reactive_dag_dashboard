defmodule ReactiveDagDashboard.PageLive do
  @moduledoc """
  The dashboard itself: the graph, per-cell state, and the last drain's trace.

  ## What it renders (and where the data comes from)

  Nothing here computes anything — every panel is a read from
  `ReactiveDag.Insights`:

  | panel | source |
  |---|---|
  | the DAG, laid out by depth | `Insights.levels/1` |
  | each node's badge | `Insights.summary/1` — status histogram + key count |
  | what the next drain would do | `Insights.pending/1` |
  | the drain waterfall | `Insights.last_report/0` |

  ## Refresh

  Per-cell state is a read of each node's own resource — one query per cell — so
  the page polls on an interval rather than subscribing: a live-by-default
  dashboard over a large graph is a self-inflicted load problem. The interval is
  configurable; the graph structure is rebuilt per mount, since it changes only
  on deploy.

  ## Degrading

  `Insights` returns structure even when a node's rows cannot be read (an
  unmigrated table, a policy, a data layer that is not up): the cell reports no
  statuses and a zero key count. The dashboard renders that as an unknown cell
  rather than an empty one, because "I could not look" and "there is nothing
  there" are different claims and only one of them is good news.
  """
  use Phoenix.LiveView

  alias ReactiveDag.Insights

  alias ReactiveDagDashboard.LiveUpdates

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:base_path, "/")
     |> assign(:selected, nil)
     |> assign(:scan_result, nil)
     |> load()
     |> LiveUpdates.setup()}
  end

  # The host chooses where to mount us (`reactive_dag_dashboard "/ops/dag"`), so
  # patch links cannot assume a prefix. The request URI is the one thing that
  # knows it: strip the route's own suffix off the current path and keep the
  # rest as the base every link is built from.
  @impl true
  def handle_params(params, uri, socket) do
    id = params["cell_id"]

    {:noreply,
     socket
     |> assign(:selected, id)
     |> assign(:base_path, base_path(uri, id))}
  end

  defp base_path(uri, id) do
    path = URI.parse(uri).path || "/"
    suffix = if id, do: "cell/#{id}", else: ""

    path
    |> String.replace_suffix(suffix, "")
    |> then(&if String.ends_with?(&1, "/"), do: &1, else: &1 <> "/")
  end

  # Running a scanner is the one thing this page DOES rather than displays.
  #
  # It ENQUEUES rather than polls inline, for two reasons. A crawl can take
  # minutes, and a synchronous poll would block this LiveView process — the page
  # would appear hung to the person who pressed the button. And a poll that only
  # writes rows is half the job: `ReactiveDag.ScanWorker` marks the frontier and
  # drains, so the change actually reaches everything downstream.
  #
  # The result arrives the way every other change does: the worker's drain emits
  # telemetry, the observer rebroadcasts it, and this page re-reads the cells that
  # moved. There is nothing to poll for here.
  @impl true
  def handle_event("scan", %{"cell" => cell_id, "mode" => mode}, socket) do
    {message, reload?} =
      case enqueue_scan(cell_id, mode, socket.assigns) do
        :queued ->
          {"scan of #{cell_id} queued — results will appear as it drains", false}

        {:ran, %{unreachable: []} = result} ->
          {"scanned #{cell_id}: #{summarise(result)}#{across_leaves(result)}", true}

        # An outage is not a quiet success. A scan that could not look must not
        # render as a scan that found nothing — the honest gap, on screen.
        {:ran, %{unreachable: up} = result} ->
          {"scanned #{cell_id}: #{summarise(result)}#{across_leaves(result)}, " <>
             "#{length(up)} upstream(s) unreachable — results are incomplete", true}

        :no_scanner ->
          {"#{cell_id} has no scanner", false}

        {:error, reason} ->
          {"scan failed: #{inspect(reason)}", false}
      end

    socket = assign(socket, :scan_result, message)
    {:noreply, if(reload?, do: load(socket), else: socket)}
  end

  # Reprocessing is the second thing this page DOES. Same split as the scan: the
  # library owns what it means, the page owns that someone asked for it now.
  @impl true
  def handle_event("reprocess", %{"cell" => cell_id} = params, socket) do
    args =
      %{"cell" => cell_id, "reason" => "dashboard"}
      |> put_where(params)
      |> put_plan(socket.assigns.plan_mfa)

    message =
      case run_reprocess(args, socket.assigns.plan, cell_id, params) do
        :queued -> "reprocess of #{describe(cell_id, params)} queued"
        {:ran, m} -> "reprocessed #{describe(cell_id, params)}: #{outcome(m)}"
        :nothing_selected -> "nothing to reprocess in #{describe(cell_id, params)}"
        {:error, reason} -> "reprocess failed: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:scan_result, message) |> load()}
  end

  defp enqueue_scan(cell_id, mode, assigns) do
    case assigns.controls[cell_id] do
      nil ->
        :no_scanner

      control ->
        run_scan(cell_id, scan_opts(mode, control), assigns)
    end
  end

  # Queue it when the library's worker is available — a crawl can take minutes,
  # and a synchronous poll would block this LiveView process, so the page would
  # look hung to whoever pressed the button.
  #
  # Without Oban (the library's dependency on it is optional, and a host may run
  # this dashboard purely for display) fall back to running it here. Slower and
  # blocking, but correct: `refresh/3` marks the frontier either way, which is
  # the part that makes a scan reach anything downstream.
  defp run_scan(cell_id, opts, assigns) do
    if Code.ensure_loaded?(ReactiveDag.ScanWorker) and oban_running?() do
      %{"cell" => cell_id}
      |> put_opts(opts)
      |> put_plan(assigns.plan_mfa)
      |> ReactiveDag.ScanWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :queued
        {:error, reason} -> {:error, reason}
      end
    else
      inline_scan(assigns.plan, cell_id, opts)
    end
  end

  defp inline_scan(plan, cell_id, opts) do
    case ReactiveDag.Source.refresh(plan, cell_id, opts) do
      {:ok, result} -> {:ran, result}
      {:error, :no_scanner} -> :no_scanner
      {:error, reason} -> {:error, reason}
    end
  end

  defp oban_running? do
    is_pid(Process.whereis(Oban))
  rescue
    _ -> false
  end

  defp put_opts(args, []), do: args

  defp put_opts(args, opts),
    do: Map.put(args, "opts", Map.new(opts, fn {k, v} -> {to_string(k), v} end))

  # The worker builds the plan itself — a job argument cannot carry one — so it
  # is told the same MFA this page was given, rather than relying on the host
  # having also set `config :reactive_dag, plan_mfa:`.
  defp put_plan(args, {m, f, a}),
    do: Map.put(args, "plan_mfa", [to_string(m), to_string(f), a])

  # `detail` says WHY each key changed, which is the difference between "4 keys
  # changed" and "2 new, 1 updated, 1 withdrawn". A scanner only has it if it
  # reconciles through the library and passes it back, so fall back to the count.
  defp summarise(%{detail: %{} = d}) do
    case Enum.reject(
           [
             {length(d.created), "new"},
             {length(d.updated), "updated"},
             {length(d.revived), "returned"},
             {length(d.retired), "withdrawn"}
           ],
           fn {n, _} -> n == 0 end
         ) do
      [] -> "nothing changed"
      parts -> Enum.map_join(parts, ", ", fn {n, label} -> "#{n} #{label}" end)
    end
  end

  defp summarise(%{changed: changed}), do: "#{length(changed)} key(s) changed"

  # A scanner may still return `changed:` keyed BY LEAF, marking several cells
  # from one poll — `Source.refresh/3` honours it. Reporting only the cell whose
  # button was pressed would then hide half the work.
  #
  # It is no longer the recommended shape: a source is a node, so one crawl
  # feeding several cells is a source with several consumers, and the drain
  # reaches them. This stays for hosts that mark directly, and renders nothing
  # for the common case where a poll marks one cell.
  defp across_leaves(%{marked: marked}) when map_size(marked) > 1 do
    detail =
      marked
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(", ", fn {leaf, keys} -> "#{leaf} #{length(keys)}" end)

    " across #{map_size(marked)} leaves — #{detail}"
  end

  defp across_leaves(_), do: ""

  defp put_where(args, %{"column" => c, "value" => v}), do: Map.put(args, "where", %{c => v})
  defp put_where(args, _params), do: args

  defp describe(cell_id, %{"column" => c, "value" => v}), do: "#{cell_id} (#{c} = #{v})"
  defp describe(cell_id, _params), do: "#{cell_id} (whole cell)"

  # `changed` alone cannot distinguish "nothing needed redoing" from "the request
  # never reached the rows". Saying how many were freed to re-run alongside how
  # many moved makes a genuine no-op readable as one.
  defp outcome(%{changed: changed} = m) do
    case m[:invalidated] do
      n when is_integer(n) and n > 0 -> "#{n} re-run, #{changed} changed"
      _ -> "#{changed} changed"
    end
  end

  defp outcome(_), do: "done"

  # Queue it when Oban is there — a reprocess can drain a large subtree, and
  # blocking the LiveView on it would look hung.
  #
  # Without Oban, run the SAME worker inline rather than re-deriving what it
  # does. That is not just less code: a reprocess has to clear the stored
  # fingerprint before marking, or a `per_key` node skips the very rows it was
  # asked to redo. This page reimplemented the marking once and silently missed
  # that step — the button worked and nothing happened. A second copy of a rule
  # this subtle is a copy that will drift again.
  defp run_reprocess(args, _plan, _cell_id, _params) do
    cond do
      not Code.ensure_loaded?(ReactiveDag.ReprocessWorker) ->
        {:error, :reprocess_worker_unavailable}

      oban_running?() ->
        case args |> ReactiveDag.ReprocessWorker.new() |> Oban.insert() do
          {:ok, _job} -> :queued
          {:error, reason} -> {:error, reason}
        end

      true ->
        inline_reprocess(args)
    end
  end

  # `perform/1` takes the job it would have been given. An inline run is
  # synchronous, so listen to the worker's own telemetry for the duration and
  # report what it measured rather than re-counting it here.
  defp inline_reprocess(args) do
    handler = "reactive-dag-dashboard-reprocess-#{inspect(self())}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:reactive_dag, :reprocess, :stop],
      fn _e, measurements, _meta, _ -> send(test_pid, {:reprocess_stop, measurements}) end,
      nil
    )

    try do
      # `perform/1` returns `:ok` even for a cell absent from the plan — it logs
      # and declines rather than failing a job that would fail identically on
      # every retry. So the telemetry, not the return value, is what says
      # whether anything happened; no event means nothing was selected.
      :ok = ReactiveDag.ReprocessWorker.perform(%Oban.Job{args: args})

      receive do
        {:reprocess_stop, m} -> {:ran, m}
      after
        0 -> :nothing_selected
      end
    after
      :telemetry.detach(handler)
    end
  end

  # What each cell declared a human may select it by. A cell that declared
  # nothing gets no reprocess control — offering one would imply a choice the
  # node never said it had.
  defp slices_by_cell(plan) do
    for {id, cell} <- plan.cells,
        slices = ReactiveDag.Node.Rows.slices(cell),
        slices != [],
        into: %{},
        do: {id, slices}
  end

  defp scan_opts("full", control), do: full_scan_opts(control)
  defp scan_opts(_default, _control), do: []

  # a "full" scan overrides each declared default with its opposite, which is the
  # only general inversion available: the library knows the standing args, not
  # what they mean.
  defp full_scan_opts(nil), do: []

  defp full_scan_opts(%{args: args}) do
    Enum.map(args, fn
      {k, v} when is_boolean(v) -> {k, not v}
      {k, _v} -> {k, nil}
    end)
  end

  defp origin_label(%{origin: %{label: label}}), do: label
  defp origin_label(%{source: mod}), do: inspect(mod)

  defp scan_label(%{args: []}), do: "run scan"
  defp scan_label(_control), do: "quick scan"

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

  # the drain finished: `pending` and the retained report both moved, and neither
  # is per-cell, so this one is a full reload.
  def handle_info({:drain_done, _report}, socket) do
    {:noreply, socket |> LiveUpdates.seen_event() |> load()}
  end

  def handle_info({:drain_failed, _reason}, socket) do
    {:noreply, LiveUpdates.seen_event(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # every read goes through Insights, so the dashboard never reaches into
  # reactive_dag's internals — and a change to how a cell's state is derived is
  # the library's business, not this page's.
  defp load(socket) do
    {mod, fun, args} = socket.assigns.plan_mfa
    plan = apply(mod, fun, args)

    socket
    |> assign(:plan, plan)
    |> assign(:levels, Insights.levels(plan))
    |> assign(:status, Map.new(Insights.summary(plan), &{&1.id, &1}))
    |> assign(:pending, MapSet.new(Insights.pending(plan)))
    |> assign(:report, Insights.last_report())
    |> assign(:controls, ReactiveDag.Source.controls(plan))
    |> assign(:slices, slices_by_cell(plan))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="rdd">
      <nav class="rdd-tabs">
        <.link patch={String.trim_trailing(@base_path, "/") |> nonempty("/")} class="rdd-active">graph</.link>
        <.link patch={"#{@base_path}from"}>where a change goes</.link>
        <span class={"rdd-live rdd-live-#{@live?}"} title={live_hint(@live?)}>
          <%= if @live?, do: "live", else: "polling" %>
        </span>
        <.link patch={"#{@base_path}into"}>what feeds this</.link>
      </nav>

      <h1>reactive_dag</h1>

      <p :if={@levels == []}>No cells in this plan.</p>

      <section :for={{depth, cells} <- @levels} class="rdd-depth">
        <h2>depth <%= depth %></h2>
        <ul>
          <li :for={cell <- cells} class={cell_class(@status[cell.id])}>
            <.link patch={"#{@base_path}cell/#{cell.id}"}><%= cell.id %></.link>

            <span :if={cell.leaf?} class="rdd-badge">leaf</span>
            <span :if={MapSet.member?(@pending, cell.id)} class="rdd-badge">pending</span>
            <span class="rdd-count" title={count_title(@status[cell.id])}><%= key_count(@status[cell.id]) %></span>

            <span :for={{status, n} <- statuses(@status[cell.id])} class="rdd-status">
              <%= status %>&nbsp;<%= n %>
            </span>
          </li>
        </ul>
      </section>

      <aside :if={@selected && @status[@selected]} class="rdd-drawer">
        <h2><%= @selected %></h2>
        <.link patch={@base_path}>close</.link>

        <dl>
          <dt>op</dt>
          <dd><%= @status[@selected].op || "—" %></dd>
          <dt>inputs</dt>
          <dd><%= Enum.join(@status[@selected].inputs, ", ") |> blank("none (leaf)") %></dd>
          <dt>keys</dt>
          <dd><%= key_count(@status[@selected]) %></dd>
        </dl>

        <section :if={@controls[@selected]} class="rdd-scan">
          <h3>scanner</h3>

          <p class="rdd-origin">
            <%= origin_label(@controls[@selected]) %>
            <span :if={@controls[@selected].every} class="rdd-badge">
              every <%= @controls[@selected].every %>
            </span>
          </p>

          <div class="rdd-actions">
            <button phx-click="scan" phx-value-cell={@selected} phx-value-mode="default">
              <%= scan_label(@controls[@selected]) %>
            </button>

            <button
              :if={@controls[@selected].args != []}
              phx-click="scan"
              phx-value-cell={@selected}
              phx-value-mode="full"
              title={"overrides #{inspect(@controls[@selected].args)}"}
            >
              full scan
            </button>
          </div>

        </section>

        <section :if={@slices[@selected]} class="rdd-scan">
          <h3>reprocess</h3>

          <p class="rdd-origin">
            re-derive rows whose inputs have not changed — after a code or prompt change
          </p>

          <div :for={slice <- @slices[@selected]} class="rdd-actions">
            <span class="rdd-via"><%= slice.label %></span>

            <button
              :for={value <- slice.values || []}
              phx-click="reprocess"
              phx-value-cell={@selected}
              phx-value-column={slice.column}
              phx-value-value={value}
            >
              <%= value %>
            </button>
          </div>

          <div class="rdd-actions">
            <button phx-click="reprocess" phx-value-cell={@selected} title="and everything below it">
              whole cell
            </button>
          </div>
        </section>

        <p :if={@scan_result} class="rdd-scan-result"><%= @scan_result %></p>

        <section :if={@status[@selected].failing_sample != []}>
          <h3>failing</h3>
          <ul>
            <li :for={key <- @status[@selected].failing_sample}><%= key %></li>
          </ul>
        </section>
      </aside>

      <section :if={@report} class="rdd-report">
        <h2>last drain</h2>
        <p>
          <%= length(@report.report.steps) %> steps ·
          <%= @report.report.passes %> passes ·
          <%= div(@report.report.duration_us, 1000) %>ms ·
          <%= @report.at %>
        </p>

        <ol>
          <li :for={step <- @report.report.steps}>
            <%= step.cell %>
            — claimed <%= length(step.claimed) %>, changed <%= length(step.changed) %>
            <span :if={step.triggered_by} class="rdd-cause">← <%= step.triggered_by %></span>
          </li>
        </ol>
      </section>
    </main>
    """
  end

  # "nothing changed" and "I am not being told about changes" look identical on a
  # static page, so the mode is stated rather than left to be inferred.
  defp live_hint(true), do: "subscribed to drain telemetry — updates arrive as they happen"

  defp live_hint(false),
    do: "no drain events; polling. Call ReactiveDagDashboard.Observer.attach/1 to go live."

  defp nonempty("", fallback), do: fallback
  defp nonempty(path, _fallback), do: path

  # a cell whose rows could not be read reports no statuses AND no keys. That is
  # NOT the same as an empty cell, and must not render as a quiet one.
  # dashed-and-dimmed means "I could not look". An empty table and a node that
  # keeps its rows elsewhere are both fine, and must not wear the warning.
  defp cell_class(nil), do: "rdd-cell rdd-unknown"
  defp cell_class(%{rows: :unreadable}), do: "rdd-cell rdd-unknown"
  defp cell_class(%{rows: :elsewhere}), do: "rdd-cell rdd-elsewhere"
  defp cell_class(_status), do: "rdd-cell"

  # `key_count: 0` is three different states, and only one is a problem. The
  # library says which in `rows:` — a real table that is empty, a node that keeps
  # its rows elsewhere (the write-elsewhere and escape-hatch shapes), or a read
  # that actually failed. Showing `?` for all three raises an alarm on two
  # non-problems, and the loudest reading wins: a publish root, often the node an
  # app actually reads, rendered as broken.
  defp key_count(nil), do: "?"
  defp key_count(%{rows: :unreadable}), do: "?"
  defp key_count(%{rows: :elsewhere}), do: "—"
  defp key_count(%{key_count: n}), do: n

  defp count_title(nil), do: "no status for this cell"
  defp count_title(%{rows: :unreadable}), do: "could not read this node's rows"

  defp count_title(%{rows: :elsewhere}),
    do: "this node keeps its rows elsewhere — nothing to count here"

  defp count_title(%{key_count: 0}), do: "no rows"
  defp count_title(%{key_count: n}), do: "#{n} keys"

  # a nil status is "this node has no :status column" — a rollup, not a verdict.
  # Showing a `nil` chip would be noise, so only real statuses are chipped.
  defp statuses(nil), do: []

  defp statuses(%{statuses: statuses}) do
    statuses
    |> Enum.reject(fn {status, _n} -> is_nil(status) end)
    |> Enum.sort()
  end

  defp blank("", fallback), do: fallback
  defp blank(value, _fallback), do: value
end
