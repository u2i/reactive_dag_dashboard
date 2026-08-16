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

  def enqueue_scan(cell_id, mode, assigns) do
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

  def oban_running? do
    is_pid(Process.whereis(Oban))
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
  def summarise(%{detail: %{} = d}) do
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

  def summarise(%{changed: changed}), do: "#{length(changed)} key(s) changed"

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
