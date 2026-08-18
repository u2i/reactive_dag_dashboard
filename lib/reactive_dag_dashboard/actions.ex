defmodule ReactiveDagDashboard.Actions do
  @moduledoc """
  Running a scan or a reprocess, and saying what happened.

  Split out of the LiveView because none of it is about layout: it decides
  whether to queue or run inline, threads the plan through a job argument, and
  turns a result into a sentence. The page changed shape; this did not.

  ## Queue or run inline

  With Oban available and running, both actions enqueue — a crawl can take
  minutes, and a synchronous poll would block the LiveView so the page looks
  hung to whoever pressed the button. Without Oban they run here: slower and
  blocking, but correct, since the marking and draining are the same either way.
  """

  require Logger

  @doc """
  Poll one source, optionally narrowed to a declared slice.

  `params` is the click's own payload, so a scan button carrying a slice
  selection reaches `poll/1` with it. That used to be dropped: `mode` was read
  and everything else discarded, so `scan_opts/2` could return only `[]` or the
  declared args inverted, and a scanner able to fetch one fiscal year had no way
  to be asked for one from this page (u2i/reactive_dag_dashboard#29).

  The selection is translated by the LIBRARY — `Rows.poll_opts/2` maps the
  column a button was rendered under to the name the scanner spells it with,
  which are deliberately allowed to differ. Doing it here would put a
  translation table in the dashboard, where it would drift from the DSL that
  declares it.
  """
  def enqueue_scan(cell_id, mode, params, assigns) do
    case assigns.controls[cell_id] do
      nil ->
        :no_scanner

      control ->
        opts = Keyword.merge(scan_opts(mode, control), slice_opts(assigns, cell_id, params))
        run_scan(cell_id, opts, assigns)
    end
  end

  # A slice selection, in the scanner's own vocabulary — or nothing, when the
  # click carried none. `poll_opts/2` ignores a column the node never declared,
  # so a stale button cannot smuggle an option into `poll/1`.
  defp slice_opts(assigns, cell_id, %{"column" => column, "value" => value}) do
    case assigns.plan.cells[cell_id] do
      nil -> []
      cell -> ReactiveDag.Node.Rows.poll_opts(cell, %{column => value})
    end
  end

  defp slice_opts(_assigns, _cell_id, _params), do: []

  # Queue it when the library's worker is available — a crawl can take minutes,
  # and a synchronous poll would block this LiveView process, so the page would
  # look hung to whoever pressed the button.
  #
  # Without Oban (the library's dependency on it is optional, and a host may run
  # this dashboard purely for display) fall back to running it here. Slower and
  # blocking, but correct: `refresh/3` marks the frontier either way, which is
  # the part that makes a scan reach anything downstream.

  # Queue it when the library's worker is available — a crawl can take minutes,
  # and a synchronous poll would block this LiveView process, so the page would
  # look hung to whoever pressed the button.
  #
  # Without Oban (the library's dependency on it is optional, and a host may run
  # this dashboard purely for display) fall back to running it here. Slower and
  # blocking, but correct: `refresh/3` marks the frontier either way, which is
  # the part that makes a scan reach anything downstream.
  def run_scan(cell_id, opts, assigns) do
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

  def inline_scan(plan, cell_id, opts) do
    case ReactiveDag.Source.refresh(plan, cell_id, opts) do
      {:ok, result} -> {:ran, result}
      {:error, :no_scanner} -> :no_scanner
      {:error, reason} -> {:error, reason}
    end
  end

  # `Oban.whereis/1`, not `Process.whereis(Oban)`.
  #
  # Oban does not register a process under the bare name — it supervises through
  # `Oban.Registry`, so `Process.whereis(Oban)` is nil in a perfectly healthy
  # app. The check reported Oban absent while Oban was running, both actions
  # fell through to their synchronous branch, and the buttons did nothing
  # visible (u2i/reactive_dag_dashboard#25).
  #
  # `whereis/1` is the documented way to ask and returns a pid or nil, so no
  # rescue is needed for "not running" — only for Oban not being loaded at all,
  # which is a real case since it is an optional dependency.
  def oban_running? do
    Code.ensure_loaded?(Oban) and not is_nil(Oban.whereis(Oban))
  rescue
    _ -> false
  end

  def put_opts(args, []), do: args

  def put_opts(args, opts),
    do: Map.put(args, "opts", Map.new(opts, fn {k, v} -> {to_string(k), v} end))

  # The worker builds the plan itself — a job argument cannot carry one — so it
  # is told the same MFA this page was given, rather than relying on the host
  # having also set `config :reactive_dag, plan_mfa:`.

  # The worker builds the plan itself — a job argument cannot carry one — so it
  # is told the same MFA this page was given, rather than relying on the host
  # having also set `config :reactive_dag, plan_mfa:`.
  def put_plan(args, {m, f, a}),
    do: Map.put(args, "plan_mfa", [to_string(m), to_string(f), a])

  # `detail` says WHY each key changed, which is the difference between "4 keys
  # changed" and "2 new, 1 updated, 1 withdrawn". A scanner only has it if it
  # reconciles through the library and passes it back, so fall back to the count.

  # `detail` says WHY each key changed, which is the difference between "4 keys
  # changed" and "2 new, 1 updated, 1 withdrawn". A scanner only has it if it
  # reconciles through the library and passes it back, so fall back to the count.
  # The four reconcile lists, not merely "a map under `detail:`". That key also
  # carries what the poll COST — a crawler reporting `%{tokens_in: …}` and no
  # reconcile would otherwise reach this clause and raise on a missing
  # `:created`, taking the live page down with it.
  def summarise(%{detail: %{created: _, updated: _, revived: _, retired: _} = d}) do
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

  # "nothing changed" is an ANSWER, not an absence. Without this clause an empty
  # list rendered as "0 key(s) changed", which reads as a scan that did
  # arithmetic rather than one that looked and found the world unmoved.
  # A run synthesised from telemetry has the COUNT but not the key names, so it
  # carries the count in `detail` and leaves the list truthfully empty. Reading
  # it here keeps "3 keys changed" honest on that path without the struct
  # inventing keys it does not have.
  def summarise(%{changed: [], detail: %{changed_count: n}}) when n > 0,
    do: "#{n} key#{if n == 1, do: "", else: "s"} changed"

  def summarise(%{changed: []}), do: "nothing changed"

  def summarise(%{changed: changed}),
    do: "#{length(changed)} key#{if length(changed) == 1, do: "", else: "s"} changed"

  # A scanner may still return `changed:` keyed BY LEAF, marking several cells
  # from one poll — `Source.refresh/3` honours it. Reporting only the cell whose
  # button was pressed would then hide half the work.
  #
  # It is no longer the recommended shape: a source is a node, so one crawl
  # feeding several cells is a source with several consumers, and the drain
  # reaches them. This stays for hosts that mark directly, and renders nothing
  # for the common case where a poll marks one cell.

  # A scanner may still return `changed:` keyed BY LEAF, marking several cells
  # from one poll — `Source.refresh/3` honours it. Reporting only the cell whose
  # button was pressed would then hide half the work.
  #
  # It is no longer the recommended shape: a source is a node, so one crawl
  # feeding several cells is a source with several consumers, and the drain
  # reaches them. This stays for hosts that mark directly, and renders nothing
  # for the common case where a poll marks one cell.
  def across_leaves(%{marked: marked}) when map_size(marked) > 1 do
    detail =
      marked
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(", ", fn {leaf, keys} -> "#{leaf} #{length(keys)}" end)

    " across #{map_size(marked)} leaves — #{detail}"
  end

  def across_leaves(_), do: ""

  def put_where(args, %{"column" => c, "value" => v}), do: Map.put(args, "where", %{c => v})

  def put_where(args, _params), do: args

  def describe(cell_id, %{"column" => c, "value" => v}), do: "#{cell_id} (#{c} = #{v})"

  def describe(cell_id, _params), do: "#{cell_id} (whole cell)"

  @doc """
  What a scan was asked for — the cell, and the slice when one was selected.

  Separate from `describe/2` because the unnarrowed cases differ: a reprocess
  with no slice really is "the whole cell", while a poll with no slice is just a
  scan of the source and saying "whole cell" about a crawl reads as a claim
  about rows it has not fetched yet.
  """
  def describe_scan(cell_id, %{"column" => c, "value" => v}), do: "#{cell_id} (#{c} = #{v})"

  def describe_scan(cell_id, _params), do: cell_id

  # `changed` alone cannot distinguish "nothing needed redoing" from "the request
  # never reached the rows". Saying how many were freed to re-run alongside how
  # many moved makes a genuine no-op readable as one.

  # `changed` alone cannot distinguish "nothing needed redoing" from "the request
  # never reached the rows". Saying how many were freed to re-run alongside how
  # many moved makes a genuine no-op readable as one.
  def outcome(%{changed: changed} = m) do
    case m[:invalidated] do
      n when is_integer(n) and n > 0 -> "#{n} re-run, #{changed} changed"
      _ -> "#{changed} changed"
    end
  end

  def outcome(_), do: "done"

  # Queue it when Oban is there — a reprocess can drain a large subtree, and
  # blocking the LiveView on it would look hung.
  #
  # Without Oban, run the SAME worker inline rather than re-deriving what it
  # does. That is not just less code: a reprocess has to clear the stored
  # fingerprint before marking, or a `per_key` node skips the very rows it was
  # asked to redo. This page reimplemented the marking once and silently missed
  # that step — the button worked and nothing happened. A second copy of a rule
  # this subtle is a copy that will drift again.

  # Queue it when Oban is there — a reprocess can drain a large subtree, and
  # blocking the LiveView on it would look hung.
  #
  # Without Oban, run the SAME worker inline rather than re-deriving what it
  # does. That is not just less code: a reprocess has to clear the stored
  # fingerprint before marking, or a `per_key` node skips the very rows it was
  # asked to redo. This page reimplemented the marking once and silently missed
  # that step — the button worked and nothing happened. A second copy of a rule
  # this subtle is a copy that will drift again.
  def run_reprocess(args, _plan, _cell_id, _params) do
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

  # `perform/1` takes the job it would have been given. An inline run is
  # synchronous, so listen to the worker's own telemetry for the duration and
  # report what it measured rather than re-counting it here.
  def inline_reprocess(args) do
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

  def scan_opts("full", control), do: full_scan_opts(control)

  def scan_opts(_default, _control), do: []

  # a "full" scan overrides each declared default with its opposite, which is the
  # only general inversion available: the library knows the standing args, not
  # what they mean.

  # a "full" scan overrides each declared default with its opposite, which is the
  # only general inversion available: the library knows the standing args, not
  # what they mean.
  def full_scan_opts(nil), do: []

  def full_scan_opts(%{args: args}) do
    Enum.map(args, fn
      {k, v} when is_boolean(v) -> {k, not v}
      {k, _v} -> {k, nil}
    end)
  end
end
