defmodule ReactiveDagDashboard.PageLive do
  @moduledoc """
  The dashboard itself: the graph, a cell drawer, and the last drain's trace.

  ## What it renders (and where the data comes from)

  Nothing here computes anything — every panel is a read from
  `ReactiveDag.Insights` (see u2i/reactive_dag#41):

  | panel | source |
  |---|---|
  | the DAG, laid out by depth | `%ReactiveDag.Plan{cells, parents, depths}` |
  | each node's badge | `Insights.cell_status/1` — status histogram + freshness |
  | the cell drawer | `Insights.cell_status/1` + a failing-key sample |
  | the drain waterfall | the retained `%ReactiveDag.Drain.Report{}` |

  ## Refresh

  Status rollups are aggregate queries over the tuple table, so the page polls on
  an interval rather than subscribing — a live-by-default dashboard over a large
  graph is a self-inflicted load problem. The interval is configurable; the graph
  structure is rebuilt per mount, since it changes only on deploy.
  """
  use Phoenix.LiveView

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:plan_mfa, session["plan_mfa"])
     |> assign(:selected, nil)
     |> load()}
  end

  @impl true
  def handle_params(%{"cell_id" => id}, _uri, socket),
    do: {:noreply, assign(socket, :selected, id)}

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :selected, nil)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # TODO(#41): replace with ReactiveDag.Insights once it lands in the core
  # library. Kept as one function so the swap is a single edit, and so the
  # dashboard never reaches into reactive_dag's internals directly.
  defp load(socket) do
    {mod, fun, args} = socket.assigns.plan_mfa
    plan = apply(mod, fun, args)

    socket
    |> assign(:plan, plan)
    |> assign(:cells, cells_by_depth(plan))
  end

  defp cells_by_depth(%{cells: cells, depths: depths}) do
    cells
    |> Map.values()
    |> Enum.group_by(&Map.get(depths, &1.id, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="rdd">
      <h1>reactive_dag</h1>

      <p :if={@cells == []}>No cells in this plan.</p>

      <section :for={{depth, cells} <- @cells} class="rdd-depth">
        <h2>depth <%= depth %></h2>
        <ul>
          <li :for={cell <- cells}>
            <%= cell.id %>
            <span :if={cell.meta[:verdict]} class="rdd-badge">verdict</span>
            <span :if={cell.leaf?} class="rdd-badge">leaf</span>
          </li>
        </ul>
      </section>
    </main>
    """
  end
end
