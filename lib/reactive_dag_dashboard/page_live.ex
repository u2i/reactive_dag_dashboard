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

  alias ReactiveDag.{Insights, Source}

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

  # Running a scanner is the one thing this page DOES rather than displays. It
  # stays a host-triggered action — the library exposes `poll_cell/3` and the
  # page calls it — so nothing here decides when a scan should happen, only that
  # someone asked for one now.
  @impl true
  def handle_event("scan", %{"cell" => cell_id, "mode" => mode}, socket) do
    opts = scan_opts(mode, socket.assigns.controls[cell_id])

    result =
      case Source.poll_cell(socket.assigns.plan, cell_id, opts) do
        {:ok, %{changed: changed} = res} ->
          unreachable = Map.get(res, :unreachable, [])

          # An outage is not a quiet success. A scan that could not look must not
          # render as a scan that found nothing — the honest gap, on screen.
          if unreachable == [] do
            "scanned #{cell_id}: #{length(changed)} key(s) changed"
          else
            "scanned #{cell_id}: #{length(changed)} changed, " <>
              "#{length(unreachable)} upstream(s) unreachable — results are incomplete"
          end

        {:error, :no_scanner} ->
          "#{cell_id} has no scanner"

        {:error, reason} ->
          "scan failed: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(:scan_result, result) |> load()}
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
            <span class="rdd-count"><%= key_count(@status[cell.id]) %></span>

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
  defp cell_class(nil), do: "rdd-cell rdd-unknown"
  defp cell_class(%{key_count: 0}), do: "rdd-cell rdd-unknown"
  defp cell_class(_status), do: "rdd-cell"

  defp key_count(nil), do: "?"
  defp key_count(%{key_count: 0}), do: "?"
  defp key_count(%{key_count: n}), do: n

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
