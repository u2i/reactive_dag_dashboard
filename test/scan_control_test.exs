defmodule ReactiveDagDashboard.ScanControlTest do
  @moduledoc """
  The scan control — running a scanner from the page.

  This is the one thing the dashboard *does* rather than displays, and the split
  matters: the library exposes `Source.poll_cell/3` and `Source.controls/1`, and
  the page renders and calls them. Nothing here decides when a scan should
  happen, only that someone asked for one now.

  `controls/1` is what makes the control renderable without the page knowing
  which scanners are expensive: a leaf that declared `args:` gets offered a full
  scan alongside its cheap default, and one that declared nothing gets a plain
  "run scan". A cell with no scanner gets no control at all — offering one would
  imply a capability that does not exist.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDagDashboard.FixtureGraph

  @endpoint ReactiveDagDashboard.TestEndpoint
  @path "/ops/dag"

  setup do
    start_supervised!(%{
      id: FixtureGraph.ExpenseScan,
      start: {FixtureGraph.ExpenseScan, :start_link, []}
    })

    start_supervised!(%{
      id: ReactiveDagDashboard.FakeRepo,
      start: {ReactiveDagDashboard.FakeRepo, :start_link, []}
    })

    prev = Application.get_env(:reactive_dag, :repo)
    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)

    # WHAT A SCAN NOW DOES, captured.
    #
    # A poll used to MARK a dirty frontier and a drain came along later to read
    # it, so this file asserted on the marks a scan left behind. A poll now
    # enqueues a cascade per changed leaf and returns — there is no queue to
    # inspect, and the default enqueuer is Oban's, which raises outright when no
    # Oban instance is running.
    #
    # `:cascade_enqueuer` is the library's own seam for a host with its own
    # queue or a test without one. Recording the enqueue is the direct successor
    # to reading the marks: it is the same question — "did this scan reach
    # anything downstream" — asked of the mechanism that now answers it.
    prev_enqueuer = Application.get_env(:reactive_dag, :cascade_enqueuer)
    test_pid = self()

    Application.put_env(:reactive_dag, :cascade_enqueuer, fn cell, keys, opts ->
      send(test_pid, {:cascade_enqueued, cell, keys, opts})
      {:ok, :recorded}
    end)

    on_exit(fn ->
      Application.put_env(:reactive_dag, :repo, prev)

      if prev_enqueuer,
        do: Application.put_env(:reactive_dag, :cascade_enqueuer, prev_enqueuer),
        else: Application.delete_env(:reactive_dag, :cascade_enqueuer)
    end)

    FixtureGraph.seed()
    :ok
  end

  # The status line only. Cell ids appear throughout the page, so matching the
  # whole document would pass on text that has nothing to do with the message.
  defp scan_message(html) do
    case Regex.run(~r/<div class="rdd-alert"[^>]*>(.*?)<\/div>/s, html) do
      [_, msg] -> msg
      nil -> ""
    end
  end

  # the page is one view now: a cell is a route, not a drawer over an index
  defp drawer(cell_id) do
    {:ok, view, html} = live(build_conn(), "#{@path}/cell/#{cell_id}")
    {view, html}
  end

  describe "what gets a control" do
    test "a scanned leaf offers one, labelled with its origin" do
      {_view, html} = drawer("expenses")

      assert html =~ "scanner"
      assert html =~ "Finance export", "origin/0 finally has a consumer"
      assert html =~ "every 0 * * * *"
    end

    test "a leaf declaring args offers BOTH a quick and a full scan" do
      {_view, html} = drawer("expenses")

      assert html =~ "quick scan"
      assert html =~ "full scan"
    end

    test "a derived cell gets no control — it has no scanner to run" do
      # asserted on the MARKUP: the stylesheet names every class, so matching
      # the whole response finds the rule rather than the control
      {_view, html} = drawer("category_health")
      body = String.replace(html, ~r/<style>.*?<\/style>/s, "")

      refute body =~ ~s|class="rdd-scan"|
      refute body =~ "run scan"
    end
  end

  describe "running it" do
    test "a scan ENQUEUES a cascade, so the change reaches downstream" do
      # the bug this replaced: the page called `poll_cell/3`, which writes rows
      # and propagates nothing — so a scan from the UI changed the leaf and
      # never recomputed anything above it.
      #
      # The evidence moved with the engine. It used to be a dirty mark on the
      # frontier, which a drain would later read; it is now an enqueued cascade
      # naming the leaf and the keys that moved. Same question — does a scan
      # from this page reach anything downstream — and the new mechanism is
      # strictly more informative, since the enqueue names the keys where a mark
      # only named the cell.
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert_received {:cascade_enqueued, "expenses", ["e1"], _opts},
                      "a scan that enqueues no cascade recomputes nothing"
    end

    test "the default button polls with the leaf's declared args" do
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      assert opts[:recent] == true, "the cheap default, without the page knowing what it means"
    end

    test "the full button inverts the declared default" do
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{"cell" => "expenses", "mode" => "full"})

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      assert opts[:recent] == false
    end

    test "the result is reported back on the page" do
      {view, _} = drawer("expenses")

      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert html =~ "scanned expenses"
      # the detail turns "1 key(s) changed" into what actually happened
      assert html =~ "1 new"
    end

    test "a cell with no scanner says so rather than failing" do
      {view, _} = drawer("category_health")

      html = render_click(view, "scan", %{"cell" => "category_health", "mode" => "default"})

      assert html =~ "has no scanner"
    end
  end

  describe "scanning ONE SLICE — asking the source for part of its upstream" do
    test "the selected slice reaches poll/1 under the SCANNER's name" do
      # the gap this closes: a slice could be reprocessed but never SCANNED, so
      # a crawler able to fetch one fiscal year had no way to be asked for one
      # from this page (#29). The fixture spells it `fiscal:` while the column
      # is `fiscal_year`, so this fails if the translation is skipped.
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{
        "cell" => "expenses",
        "mode" => "default",
        "column" => "fiscal_year",
        "value" => "FY25"
      })

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      assert opts[:fiscal] == "FY25"
      refute opts[:fiscal_year], "the column name is the UI's, not the scanner's"
    end

    test "and the declared args still travel with it" do
      # narrowing to a slice must not silently drop the standing `recent: true`
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{
        "cell" => "expenses",
        "mode" => "default",
        "column" => "fiscal_year",
        "value" => "FY25"
      })

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      assert opts[:recent] == true
    end

    test "a scan with no slice is unchanged" do
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      refute Keyword.has_key?(opts, :fiscal), "nothing was selected, so nothing is narrowed"
    end

    test "a column the node never declared as a slice is ignored" do
      # the library drops it rather than passing it through: an unrecognised
      # option would otherwise reach `poll/1` looking like one the node offered
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{
        "cell" => "expenses",
        "mode" => "default",
        "column" => "nonsense",
        "value" => "x"
      })

      assert [opts] = FixtureGraph.ExpenseScan.polls()
      refute Keyword.has_key?(opts, :nonsense)
    end

    test "the scanner block offers a button per slice value" do
      # asserted on the MARKUP, because `render_click` sends the event whether
      # or not anything on the page emits it — so a handler test alone would
      # pass against a page with no buttons
      {_view, html} = drawer("expenses")

      assert html =~ ~s|phx-value-column="fiscal_year"|
      assert html =~ "just fiscal_year"
    end

    test "the message says WHAT was scanned, not just that it was" do
      # "scanned expenses" for a one-year poll reads as a full crawl that
      # happened to be fast
      {view, _} = drawer("expenses")

      html =
        render_click(view, "scan", %{
          "cell" => "expenses",
          "mode" => "default",
          "column" => "fiscal_year",
          "value" => "FY25"
        })

      assert scan_message(html) =~ "fiscal_year = FY25"
    end

    test "an unnarrowed scan is not described as a whole cell" do
      # `describe/2`'s wording belongs to reprocess: a poll with no slice is
      # just a scan of the source, and "whole cell" claims something about rows
      # it has not fetched yet
      {view, _} = drawer("expenses")

      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert scan_message(html) =~ "scanned expenses"
      refute scan_message(html) =~ "whole cell"
    end
  end

  describe "reporting what a scan did" do
    test "a scanner without detail falls back to a count" do
      {view, _} = drawer("expenses")
      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      # this fixture DOES report detail, so it says what rather than how many
      refute html =~ "key(s) changed"
    end

    test "a scan that changed nothing says so plainly" do
      # the deep pass reaches a downed archive: no keys, and detail all empty
      {view, _} = drawer("expenses")
      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "full"})

      assert html =~ "nothing changed"
    end
  end

  describe "an outage is not a quiet success" do
    test "the page says results are incomplete, rather than reporting a clean scan" do
      # the honest gap, on screen: a scan that could not look must not render as
      # a scan that found nothing. The fixture echoes `stub_unreachable` from its
      # opts, so a full-scan click carries it through the real handler.
      {view, _} = drawer("expenses")

      # the fixture's deep pass reaches an archive that is down
      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "full"})

      assert html =~ "unreachable"
      assert html =~ "results are incomplete"
    end

    test "a clean scan does not mention outages" do
      {view, _} = drawer("expenses")

      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert html =~ "scanned expenses"
      refute html =~ "unreachable"
    end
  end

  describe "a source feeding several consumers" do
    # One crawl whose rows land in two downstream cells. That used to be a
    # MARKING concern — `refresh/3` marked both leaves from one poll, and the
    # message had to name each or hide half the work.
    #
    # A source is a node now, so the poll marks ONE cell and the drain carries
    # it to the consumers. The scan message is about the cell that was scanned;
    # what the change reached is the drain's business, and the hierarchy shows
    # it.
    test "the message is about the cell that was scanned" do
      {view, _} = drawer("council_portal")

      html = render_click(view, "scan", %{"cell" => "council_portal", "mode" => "default"})

      assert scan_message(html) =~ "scanned council_portal"
      refute scan_message(html) =~ "across"
    end

    test "and its consumers are reached by the drain, not by the marking" do
      {view, _} = drawer("council_portal")

      render_click(view, "scan", %{"cell" => "council_portal", "mode" => "default"})

      # `minutes` and `resolutions` are children of the scanned cell — no
      # scan-specific machinery involved
      plan = FixtureGraph.plan()
      assert Enum.sort(plan.parents["council_portal"]) == ["minutes", "resolutions"]
    end

    test "a single-leaf scan still reads as one cell" do
      # the common case must not acquire a leaf breakdown it does not need
      {view, _} = drawer("expenses")

      html = render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert scan_message(html) =~ "scanned expenses"
      refute scan_message(html) =~ "across"
    end
  end

  describe "reprocessing a fingerprinted node" do
    # The bug this guards: `per_key` skips rows whose declared inputs have not
    # moved, and after a code change they have not. So a reprocess that only
    # MARKS claims the keys and re-runs nothing — the button works and nothing
    # happens. The library's worker clears the stored fingerprint first; this
    # page must go through it rather than reimplementing the marking, which is
    # exactly how it lost that step once already.
    setup do
      start_supervised!(%{
        id: FixtureGraph.Notes,
        start: {FixtureGraph.Notes, :start_link, []}
      })

      FixtureGraph.Notes.reset()
      :ok
    end

    test "the action actually runs again" do
      {view, _} = drawer("expense_notes")

      html = render_click(view, "reprocess", %{"cell" => "expense_notes"})

      assert FixtureGraph.Notes.calls() != [],
             "the fingerprint was not cleared, so every claimed row was skipped"

      assert html =~ "reprocessed expense_notes"
    end

    test "a slice re-runs only its slice" do
      {view, _} = drawer("expense_notes")

      render_click(view, "reprocess", %{
        "cell" => "expense_notes",
        "column" => "fiscal_year",
        "value" => "FY25"
      })

      # e1 is the FY25 row, at 500.0; e2 (FY24, 40.0) must not be re-described
      assert FixtureGraph.Notes.calls() == [500.0]
    end

    test "the message reports how many were freed to re-run" do
      {view, _} = drawer("expense_notes")

      html =
        render_click(view, "reprocess", %{
          "cell" => "expense_notes",
          "column" => "fiscal_year",
          "value" => "FY25"
        })

      # "changed" alone cannot separate "nothing needed redoing" from "the
      # request never reached the rows"
      assert html =~ "1 re-run"
    end
  end

  describe "the reprocess control" do
    test "a sliceable cell offers one button per declared value" do
      {_view, html} = drawer("expenses")

      assert html =~ "reprocess"
      assert html =~ "fiscal_year"
      assert html =~ ~s|phx-value-value="FY25"|
      assert html =~ ~s|phx-value-value="FY24"|
    end

    test "a cell declaring no slice gets no reprocess control" do
      # offering one would imply a choice the node never said it had
      {_view, html} = drawer("category_health")

      refute html =~ "phx-click=\"reprocess\""
    end

    test "reprocessing a slice claims ONLY that slice's keys" do
      # the message is not the evidence — watch what the drain actually claimed
      test_pid = self()

      :telemetry.attach(
        "reprocess-claims",
        # `:cell_start`, not `:step`. What this test asks is what the recompute
        # was CLAIMED for, and the two events carry different halves of that: a
        # cascade puts `claimed_keys` on the event that fires BEFORE a cell runs
        # and `changed_keys` on the one that fires after. Asking `:step` for a
        # claim gets nil, which `assert_received` reports as a missing message
        # rather than as the wrong question.
        [:reactive_dag, :cascade, :cell_start],
        fn _e, _m, meta, _ -> send(test_pid, {:claimed, meta.cell, meta.claimed_keys}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("reprocess-claims") end)

      {view, _} = drawer("expenses")

      html =
        render_click(view, "reprocess", %{
          "cell" => "expenses",
          "column" => "fiscal_year",
          "value" => "FY25"
        })

      assert html =~ "reprocessed expenses (fiscal_year = FY25)"

      # e1 is the only FY25 row; e2 (FY24) must not be claimed
      assert_received {:claimed, "expenses", ["e1"]}
    end

    test "the whole-cell button says what it is" do
      {view, _} = drawer("expenses")

      test_pid = self()

      :telemetry.attach(
        "reprocess-all-claims",
        # `:cell_start`, not `:step`. What this test asks is what the recompute
        # was CLAIMED for, and the two events carry different halves of that: a
        # cascade puts `claimed_keys` on the event that fires BEFORE a cell runs
        # and `changed_keys` on the one that fires after. Asking `:step` for a
        # claim gets nil, which `assert_received` reports as a missing message
        # rather than as the wrong question.
        [:reactive_dag, :cascade, :cell_start],
        fn _e, _m, meta, _ -> send(test_pid, {:claimed, meta.cell, meta.claimed_keys}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("reprocess-all-claims") end)

      html = render_click(view, "reprocess", %{"cell" => "expenses"})

      assert html =~ "reprocessed expenses (whole cell)"
      assert_received {:claimed, "expenses", ["*"]}
    end

    test "it drains, so downstream actually recomputes" do
      test_pid = self()

      :telemetry.attach(
        "reprocess-cascade",
        [:reactive_dag, :cascade, :step],
        fn _e, _m, meta, _ -> send(test_pid, {:step, meta.cell}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("reprocess-cascade") end)

      {view, _} = drawer("expenses")

      render_click(view, "reprocess", %{
        "cell" => "expenses",
        "column" => "fiscal_year",
        "value" => "FY25"
      })

      assert_received {:step, "expenses"}
      assert_received {:step, "category_health"}
    end
  end
end
