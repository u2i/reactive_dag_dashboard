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

  describe "the status band" do
    # The band exists because the LOG alone cannot answer "what is waiting on
    # me" — you would scroll past 25 successes to find it. What is asserted
    # here is that the blocked kinds arrive DISTINGUISHED: each needs a
    # different action (decide / revive / investigate), and a count of four
    # tells a reader nothing about what to do.
    import Phoenix.LiveViewTest

    test "each blocked kind renders its own pill" do
      html =
        render_component(&ReactiveDagDashboard.Components.status_band/1,
          outstanding: [],
          blocked: [
            %{kind: :approval, cell: "chain_verdict", detail: %{}},
            %{
              kind: :stranded,
              cell: "transcript_extract",
              detail: %{"repair" => "ReactiveDag.Suspension.revive/1"}
            },
            %{kind: :discarded, cell: "agenda_docs", detail: %{"error" => "boom"}}
          ]
        )

      assert html =~ "rdd-pill-blocked-approval"
      assert html =~ "rdd-pill-blocked-stranded"
      assert html =~ "rdd-pill-blocked-discarded"

      assert html =~ "ReactiveDag.Suspension.revive/1",
             "stranded must carry its repair — `Oban.retry_job/1` skips these " <>
               "and reports success, which a reader cannot guess"
    end

    test "empty is stated, not left blank" do
      # An empty panel reads as "not implemented", which is the one thing this
      # must not be confused with.
      html =
        render_component(&ReactiveDagDashboard.Components.status_band/1,
          outstanding: [],
          blocked: []
        )

      assert html =~ "Nothing queued or running"
      assert html =~ "Nothing waiting on a person"
    end

    test "outstanding shows its status, because queued and running differ" do
      html =
        render_component(&ReactiveDagDashboard.Components.status_band/1,
          outstanding: [
            %{status: "queued", cell_id: "a", kind: "cascade"},
            %{status: "running", cell_id: "b", kind: "scan"}
          ],
          blocked: []
        )

      assert html =~ "rdd-pill-queued"
      assert html =~ "rdd-pill-running"
    end
  end


  describe "the log view renders a row with NO step tree" do
    # THE CRASH. A persisted row carries counts only — the step tree lives in
    # the ETS entry — so `roots` is nil, and `:for={root <- run.roots}` raised
    # `Enumerable not implemented for Atom` and took the whole LiveView down on
    # mount. The runs tab did nothing at all.
    #
    # Rendered through the COMPONENT rather than the live view, because this
    # suite configures no repo — `Run.queued/2` returns nil here, so a test
    # that mounts the page renders no persisted row and proves nothing. My
    # first attempt did exactly that and passed.
    import Phoenix.LiveViewTest

    defp run_row(overrides) do
      Map.merge(
        %{
          run_id: "r1",
          at: DateTime.utc_now(),
          kind: "cascade",
          status: "done",
          parent_run_id: nil,
          polled?: false,
          scanned: "expenses",
          duration_us: 1_234,
          cascade_us: nil,
          poll_changed: 0,
          unreachable: [],
          complete?: true,
          cascaded?: true,
          cells: 3,
          suspended: 0,
          suspensions: [],
          changed: 7,
          tokens_in: 0,
          tokens_out: 0,
          tokens_by: %{},
          llm_calls: 0,
          cache_hits: 0,
          roots: []
        },
        overrides
      )
    end

    test "nil roots renders instead of crashing" do
      html =
        render_component(&ReactiveDagDashboard.Components.log/1,
          runs: [run_row(%{roots: nil})],
          activity: %{},
          cascading?: false
        )

      assert html =~ "Recorded before this node restarted",
             "a row with no recorded tree must say so"

      refute html =~ "Nothing to recompute",
             "no tree is not an empty tree — that would assert something the " <>
               "row cannot know"
    end

    test "an empty tree still says nothing was recomputed" do
      html =
        render_component(&ReactiveDagDashboard.Components.log/1,
          runs: [run_row(%{roots: []})],
          activity: %{},
          cascading?: false
        )

      assert html =~ "Nothing to recompute"
      refute html =~ "Recorded before this node restarted"
    end
  end


  describe "the status band uses the dashboard's palette" do
    import Phoenix.LiveViewTest
    # THE MISTAKE THIS CATCHES. The band shipped in light-mode Tailwind values
    # — `#fff` cards, `#f3f4f6` pills, `#e5e7eb` borders — into a page whose
    # ground is `--bg: #0e1116`. A white panel on a dark dashboard.
    #
    # Nothing caught it because every test asserted CLASS NAMES, which were
    # correct; the colours behind them were not, and no test looked at the
    # stylesheet at all.
    test "no hardcoded hex in the band's rules" do
      css = render_component(&ReactiveDagDashboard.Components.styles/1, [])

      band =
        css
        |> String.split("status band")
        |> Enum.at(1, "")
        |> String.split(".rdd-run-live")
        |> List.first()

      # COMMENTS STRIPPED FIRST. The block documents the mistake by naming the
      # offending values, so scanning raw text finds them and fails on its own
      # explanation — which is what happened the first time this ran.
      hexes =
        band
        |> String.replace(~r|/\*.*?\*/|s, "")
        |> then(&Regex.scan(~r/#[0-9a-fA-F]{3,6}\b/, &1))
        |> List.flatten()
        |> Enum.uniq()

      assert hexes == [],
             "the band must use the dashboard's tokens (var(--panel), var(--attested), " <>
               "var(--gap)) so it inherits the theme; found #{inspect(hexes)}"
    end

    test "each blocked kind maps to a semantic token" do
      css = render_component(&ReactiveDagDashboard.Components.styles/1, [])

      # Every kind `Run.blocked/1` can return needs a rule, or it renders with
      # the bare pill and a reader cannot tell it apart.
      for kind <- ~w(approval orphaned stranded discarded spend_gated) do
        assert css =~ ".rdd-pill-blocked-#{kind}",
               "blocked kind `#{kind}` has no pill rule"
      end
    end
  end

end
