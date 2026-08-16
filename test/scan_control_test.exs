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
      assert html =~ "1 key(s) changed"
    end

    test "a cell with no scanner says so rather than failing" do
      {view, _} = drawer("category_health")

      html = render_click(view, "scan", %{"cell" => "category_health", "mode" => "default"})

      assert html =~ "has no scanner"
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
end
