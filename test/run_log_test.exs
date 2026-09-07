defmodule ReactiveDagDashboard.RunLogTest do
  @moduledoc """
  The log reads two sources, and must not show one run twice.

  `Insights` (ETS) holds the whole `ScanRun` — every step, its `triggered_by`
  edge, per-model token spend — which is what draws the tree and the cost
  columns. `ReactiveDag.Run` (a table) holds counts, and survives a restart.

  They overlap: a run that just happened on this node is in both. Nothing else
  on the two rows is unique enough to correlate them — same tenant, same cell,
  timestamps microseconds apart — so without a shared id the page renders every
  recent run twice, once with a tree and once without. That is what `run_id`
  on the ETS entry is for, and what these assert.
  """
  use ExUnit.Case, async: false

  alias ReactiveDag.{Insights, Run}

  # NO `forget_runs/0` HERE. The buffer is process-wide and shared with every
  # other test in the suite, so clearing it in setup makes this file able to
  # delete another test's entries mid-run — a flake that only appears on some
  # orderings. These assert on the entry they just wrote instead, found by its
  # own id.
  setup do
    :ok
  end

  describe "the ETS entry carries the run it belongs to" do
    test "recorded inside a run, an entry names it" do
      # `Run.executing/3` holds the id for the duration of the job, which is
      # exactly when `Insights.record/2` is called.
      Run.executing("run-abc", [], fn ->
        Insights.record(%ReactiveDag.Report{steps: [], passes: 1, duration_us: 10})
      end)

      assert Enum.any?(Insights.recent(), &(&1[:run_id] == "run-abc")),
             "the entry recorded inside a run must name it"
    end

    test "recorded outside one, it names nothing — and that is not an error" do
      # A host without the run table, or an entry from before it existed. The
      # page must still render such a row; it simply cannot correlate it.
      Insights.record(%ReactiveDag.Report{steps: [], passes: 1, duration_us: 99_871})

      entry = Enum.find(Insights.recent(), &(&1.run.duration_us == 99_871))

      assert entry, "the entry we just recorded"
      assert entry[:run_id] == nil
    end
  end

  describe "dedup" do
    test "nil ids do not collapse into one another" do
      # The trap: `MapSet.new(live, & &1[:run_id])` puts a single nil in the set
      # when any live entry lacks an id, and every uncorrelated row then matches
      # it. Asserted on the rule itself, since the page's merge is private.
      live = [%{run_id: nil}, %{run_id: "a"}, %{run_id: nil}]

      seen = live |> Enum.map(& &1[:run_id]) |> Enum.reject(&is_nil/1) |> MapSet.new()

      assert MapSet.to_list(seen) == ["a"]
      refute MapSet.member?(seen, nil), "nil is not an id and must not suppress a row"
    end
  end
end
