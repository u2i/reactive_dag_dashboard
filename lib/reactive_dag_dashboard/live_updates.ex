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

  # How long a row keeps its "just ran" trail. Long enough to still be there
  # when a wide drain finishes, short enough that the page settles on its own.
  @trail_ms 12_000

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
    # `%{cell_id => %{changed: n, at: monotonic_ms}}` — what this drain has
    # touched so far. The tree renders a pulse from it, so the cascade is
    # visible AS it travels rather than only in the counts it leaves behind.
    |> Phoenix.Component.assign(:activity, %{})
    |> Phoenix.Component.assign(:draining?, false)
  end

  @doc """
  Note that `cell_id` just recomputed, changing `changed` keys.

  The drain emits a step per cell in depth order, so accumulating these IS the
  cascade: a row that has an entry has run, and the newest entry is the wave
  front. Timestamps are monotonic ms, since the only question asked of them is
  "how long ago".
  """
  @spec record_step(Phoenix.LiveView.Socket.t(), String.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  def record_step(socket, cell_id, changed) do
    entry = %{changed: changed, at: System.monotonic_time(:millisecond)}

    socket
    |> Phoenix.Component.assign(:activity, Map.put(socket.assigns.activity, cell_id, entry))
    |> Phoenix.Component.assign(:draining?, true)
  end

  @doc """
  Note that `cell_id` was SCANNED, and what the poll found.

  The trail exists so a run is visible after the fact, and a poll that found
  nothing is the case that most needs it: it dirties nothing, so it produces no
  `:drain_step` and would otherwise leave the page identical to one where the
  button was never pressed.

  `state` is `:running`, `:failed`, or the poll's `%{changed:, unreachable:}` —
  which is why "nothing changed" can be rendered as an outcome rather than
  inferred from silence.
  """
  @spec record_scan(Phoenix.LiveView.Socket.t(), String.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  def record_scan(socket, cell_id, state) do
    entry = %{scan: state, at: System.monotonic_time(:millisecond)}

    socket =
      Phoenix.Component.assign(
        socket,
        :activity,
        Map.update(socket.assigns.activity, cell_id, entry, &Map.merge(&1, entry))
      )

    # A finished scan schedules the trail to expire, like a finished drain: the
    # run you just watched is the one whose result you want to read, and a no-op
    # scan has no drain to do it for you.
    case state do
      :running ->
        Phoenix.Component.assign(socket, :draining?, true)

      _ ->
        Process.send_after(self(), :clear_trail, @trail_ms)
        Phoenix.Component.assign(socket, :draining?, false)
    end
  end

  @doc """
  The drain finished: stop claiming to be draining, and schedule the trail to
  expire.

  The trail outlives the drain deliberately — the run you just watched is the
  one you want to read the results of, and clearing it at `:stop` would erase
  the answer at the moment it became useful.
  """
  @spec finish(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def finish(socket) do
    Process.send_after(self(), :clear_trail, @trail_ms)
    Phoenix.Component.assign(socket, :draining?, false)
  end

  @doc "Drop the trail. A no-op if another drain started in the meantime."
  @spec clear_trail(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_trail(%{assigns: %{draining?: true}} = socket), do: socket
  def clear_trail(socket), do: Phoenix.Component.assign(socket, :activity, %{})

  @doc "How long a row keeps its trail, in ms."
  @spec trail_ms() :: pos_integer()
  def trail_ms, do: @trail_ms

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
    socket =
      Phoenix.Component.assign(
        socket,
        :stale_cells,
        MapSet.put(socket.assigns.stale_cells, cell_id)
      )

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
