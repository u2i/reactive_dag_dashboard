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
    on_exit(fn -> Application.put_env(:reactive_dag, :repo, prev) end)

    FixtureGraph.seed()
    :ok
  end

  # The status line only. Cell ids appear throughout the page, so matching the
  # whole document would pass on text that has nothing to do with the message.
  defp scan_message(html) do
    case Regex.run(~r/<p class="rdd-scan-result"[^>]*>(.*?)<\/p>/s, html) do
      [_, msg] -> msg
      nil -> ""
    end
  end

  defp drawer(cell_id) do
    {:ok, view, _} = live(build_conn(), @path)
    {view, render_patch(view, "#{@path}/cell/#{cell_id}")}
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
      {_view, html} = drawer("category_health")

      refute html =~ "rdd-scan"
      refute html =~ "run scan"
    end
  end

  describe "running it" do
    test "a scan MARKS the frontier, so the change reaches downstream" do
      # the bug this replaced: the page called `poll_cell/3`, which writes rows
      # and marks nothing — so a scan from the UI changed the leaf and never
      # recomputed anything above it
      {view, _} = drawer("expenses")

      render_click(view, "scan", %{"cell" => "expenses", "mode" => "default"})

      assert Enum.any?(ReactiveDagDashboard.FakeRepo.marks(), fn {cell, _} -> cell == "expenses" end),
             "a scan that marks nothing recomputes nothing"
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

  describe "a scanner feeding several leaves" do
    # One crawl of one upstream whose rows land in two cells. `refresh/3` marks
    # both from a single poll, so a message naming only the button's cell hides
    # half of what the scan just did — and the other half is where a reader
    # would go looking when a number surprises them.
    test "the message names every leaf the poll marked" do
      {view, _} = drawer("minutes")

      html = render_click(view, "scan", %{"cell" => "minutes", "mode" => "default"})

      # both cells appear all over the page — in the graph, in the tree — so
      # `html =~ "resolutions"` proves nothing. Assert on the MESSAGE.
      assert html =~ "across 2 leaves"
      assert scan_message(html) =~ "resolutions", "the second leaf this one poll also marked"
    end

    test "and says how many keys each got" do
      {view, _} = drawer("minutes")

      html = render_click(view, "scan", %{"cell" => "minutes", "mode" => "default"})

      # 1 for minutes, 2 for resolutions — a single total would read as 3 keys
      # in the cell you were looking at
      assert html =~ "minutes 1"
      assert html =~ "resolutions 2"
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
        [:reactive_dag, :drain, :step],
        fn _e, _m, meta, _ -> send(test_pid, {:claimed, meta.cell, meta.step.claimed}) end,
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
        [:reactive_dag, :drain, :step],
        fn _e, _m, meta, _ -> send(test_pid, {:claimed, meta.cell, meta.step.claimed}) end,
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
        "reprocess-drain",
        [:reactive_dag, :drain, :step],
        fn _e, _m, meta, _ -> send(test_pid, {:step, meta.cell}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("reprocess-drain") end)

      {view, _} = drawer("expenses")
      render_click(view, "reprocess", %{"cell" => "expenses", "column" => "fiscal_year", "value" => "FY25"})

      assert_received {:step, "expenses"}
      assert_received {:step, "category_health"}
    end
  end
end
