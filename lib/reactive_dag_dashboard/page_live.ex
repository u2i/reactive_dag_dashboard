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

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:base_path, "/")
     |> assign(:selected, nil)
     |> load()}
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

  @impl true
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="rdd">
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
