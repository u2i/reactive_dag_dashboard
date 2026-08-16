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
     |> assign(:selected, nil)
     |> assign(:direction, :downstream)
     |> assign(:message, nil)
     |> load()
     |> LiveUpdates.setup()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(:base_path, base_path(uri, params["cell_id"]))
     |> assign(:selected, params["cell_id"] || default_cell(socket.assigns))
     |> assign(:direction, direction(params))
     |> assign_view()}
  end

  # ── the two things this page DOES ───────────────────────────────────────────

  @impl true
  def handle_event("select", %{"cell" => cell_id}, socket) do
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}cell/#{cell_id}")}
  end

  def handle_event("direction", %{"to" => to}, socket) do
    {:noreply, socket |> assign(:direction, String.to_existing_atom(to)) |> assign_view()}
  end

  def handle_event("scan", %{"cell" => cell_id} = params, socket) do
    mode = Map.get(params, "mode", "default")

    {message, reload?} =
      case Actions.enqueue_scan(cell_id, mode, socket.assigns) do
        :queued ->
          {"scan of #{cell_id} queued — results appear as it drains", false}

        {:ran, %{unreachable: []} = result} ->
          {"scanned #{cell_id}: #{Actions.summarise(result)}#{Actions.across_leaves(result)}",
           true}

        # An outage is not a quiet success. A scan that could not look must not
        # render as a scan that found nothing.
        {:ran, %{unreachable: up} = result} ->
          {"scanned #{cell_id}: #{Actions.summarise(result)}, #{length(up)} upstream(s) " <>
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
    socket |> assign(:rows, []) |> assign(:detail, nil) |> assign(:routes, 0)
  end

  defp assign_view(%{assigns: %{plan: plan, selected: id, direction: dir}} = socket) do
    tree =
      case dir do
        :upstream -> Tree.upstream(plan, id)
        _ -> Tree.downstream(plan, id)
      end

    socket
    |> assign(:rows, Tree.hierarchy(plan, tree))
    |> assign(:routes, Tree.path_count(tree))
    |> assign(:detail, NodeDetail.build(plan, id, socket.assigns.controls))
  end

  # With nothing named, start where a change enters — the question people
  # arrive with is almost always "what happened to X", and X came from a source.
  defp default_cell(%{plan: plan}), do: plan |> Tree.roots() |> List.first()

  defp direction(%{"direction" => "upstream"}), do: :upstream
  defp direction(_), do: :downstream

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
    <main class="p-6 max-w-5xl mx-auto">
      <div class="flex items-baseline justify-between mb-4">
        <h1 class="text-xl font-semibold">reactive_dag</h1>
        <span class={["badge badge-sm", @live? && "badge-success" || "badge-ghost"]}>
          <%= if @live?, do: "live", else: "polling" %>
        </span>
      </div>

      <div :if={@message} class="alert alert-info py-2 mb-4 text-sm">
        <%= @message %>
      </div>

      <h2 class="text-xs uppercase tracking-wide opacity-50 mb-1">sources</h2>
      <.sources sources={@sources} status={@status} selected={@selected} />

      <div class="flex items-baseline gap-3 mt-6 mb-1">
        <h2 class="text-xs uppercase tracking-wide opacity-50">
          <%= if @direction == :upstream, do: "what feeds", else: "what changes" %>
        </h2>

        <div class="tabs tabs-boxed tabs-xs">
          <button
            class={["tab", @direction == :downstream && "tab-active"]}
            phx-click="direction"
            phx-value-to="downstream"
          >
            downstream
          </button>
          <button
            class={["tab", @direction == :upstream && "tab-active"]}
            phx-click="direction"
            phx-value-to="upstream"
          >
            upstream
          </button>
        </div>

        <span class="text-xs opacity-50">
          <%= @routes %> <%= if @routes == 1, do: "route", else: "routes" %>
        </span>
      </div>

      <.hierarchy rows={@rows} status={@status} selected={@selected} plan={@plan} />

      <.detail detail={@detail} />
    </main>
    """
  end
end
