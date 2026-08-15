defmodule ReactiveDagDashboard.LiveUpdates do
  @moduledoc """
  The live-update behaviour both views share: subscribe, then refresh only what
  moved.

  ## Why not just re-read everything

  `Insights.summary/1` is one `Ash.read!` **per cell** — every row of every
  node's table, on every refresh. That is affordable on a timer at 5s and
  unaffordable as a response to each drain step, which is precisely when you most
  want to be live.

  So a `:drain_step` refreshes exactly the cell it names, via
  `Insights.cell_status/2`. The cost of watching becomes proportional to real
  change — the same principle the engine itself runs on, applied to observing it.

  ## Polling remains, as a fallback

  A host that never calls `ReactiveDagDashboard.Observer.attach/1` gets no
  events, and a page that silently froze would be worse than a slow one. So the
  timer stays: slow (30s) when events are arriving, brisk (5s) when they are not.
  The UI says which mode it is in, because "nothing has changed" and "I am not
  being told about changes" look identical otherwise.

  ## Coalescing

  A drain over a wide graph emits a step per cell, and re-rendering per step
  would be a re-render per cell. Steps are accumulated and flushed on a short
  timer, so a 40-cell drain costs a handful of renders rather than forty.
  """

  @live_interval_ms 30_000
  @poll_interval_ms 5_000
  @flush_ms 150

  @doc "The interval to poll at, given whether events are arriving."
  @spec interval(boolean()) :: pos_integer()
  def interval(true), do: @live_interval_ms
  def interval(false), do: @poll_interval_ms

  @doc "How long to accumulate drain steps before re-rendering."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @doc """
  Wire a socket for live updates: subscribe to the observer's topic when a PubSub
  is configured, and start the fallback timer.

  Safe to call from `mount/3` on a disconnected render — it does nothing until
  the socket is connected, since a static render has no process to message.
  """
  @spec setup(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def setup(socket, opts \\ []) do
    pubsub = opts[:pubsub] || Application.get_env(:reactive_dag_dashboard, :pubsub)
    live? = connected?(socket) and subscribe(pubsub)

    if connected?(socket) do
      :timer.send_interval(interval(live?), self(), :refresh)
    end

    socket
    |> Phoenix.Component.assign(:live?, live?)
    |> Phoenix.Component.assign(:stale_cells, MapSet.new())
    |> Phoenix.Component.assign(:flush_scheduled?, false)
    |> Phoenix.Component.assign(:last_event_at, nil)
  end

  defp subscribe(nil), do: false

  defp subscribe(pubsub) do
    case Phoenix.PubSub.subscribe(pubsub, ReactiveDagDashboard.Observer.topic()) do
      :ok -> true
      _ -> false
    end
  end

  defp connected?(socket), do: Phoenix.LiveView.connected?(socket)

  @doc """
  Record a cell as needing a re-read, and schedule a flush if one is not already
  pending.

  Returns the socket. The caller handles `:flush_stale` and calls
  `refresh_stale/2`.
  """
  @spec mark_stale(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mark_stale(socket, cell_id) do
    socket = Phoenix.Component.assign(socket, :stale_cells, MapSet.put(socket.assigns.stale_cells, cell_id))

    if socket.assigns.flush_scheduled? do
      socket
    else
      Process.send_after(self(), :flush_stale, @flush_ms)
      Phoenix.Component.assign(socket, :flush_scheduled?, true)
    end
  end

  @doc """
  Re-read only the cells marked stale, merging them into the `:status` map.

  This is the incremental read — N cells, not the whole graph.
  """
  @spec refresh_stale(Phoenix.LiveView.Socket.t(), ReactiveDag.Plan.t()) ::
          Phoenix.LiveView.Socket.t()
  def refresh_stale(socket, plan) do
    refreshed =
      socket.assigns.stale_cells
      |> Enum.map(&{&1, ReactiveDag.Insights.cell_status(plan, &1)})
      |> Enum.reject(fn {_id, status} -> is_nil(status) end)
      |> Map.new()

    socket
    |> Phoenix.Component.assign(:status, Map.merge(socket.assigns.status, refreshed))
    |> Phoenix.Component.assign(:stale_cells, MapSet.new())
    |> Phoenix.Component.assign(:flush_scheduled?, false)
  end

  @doc """
  Note that an event arrived, so the UI can say it is live.

  A page that has been told nothing for a long time is not necessarily broken —
  it may simply be a quiet graph — but the distinction is the operator's to make,
  so the timestamp is surfaced rather than interpreted.
  """
  @spec seen_event(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def seen_event(socket) do
    socket
    |> Phoenix.Component.assign(:live?, true)
    |> Phoenix.Component.assign(:last_event_at, DateTime.utc_now())
  end
end
