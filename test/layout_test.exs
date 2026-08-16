defmodule ReactiveDagDashboard.LayoutTest do
  @moduledoc """
  Getting the host's stylesheet onto the page.

  The dashboard ships no CSS — it is daisyUI class names and inherits the host's
  theme. That contract only holds if the stylesheet is actually LINKED, and the
  first version of it never was: the layout tested `assigns[:css_path]`, nothing
  ever assigned it, and no option existed to
  (u2i/reactive_dag_dashboard#18). Every host got an unstyled page.

  These pin both routes onto the page, because "the page renders" was true
  throughout the bug.
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

    prev_repo = Application.get_env(:reactive_dag, :repo)
    prev_css = Application.get_env(:reactive_dag_dashboard, :css_path)

    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)

    on_exit(fn ->
      Application.put_env(:reactive_dag, :repo, prev_repo)
      Application.put_env(:reactive_dag_dashboard, :css_path, prev_css)
    end)

    FixtureGraph.seed()
    :ok
  end

  test "the configured stylesheet is linked" do
    Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")

    {:ok, _view, html} = live(build_conn(), @path)

    assert html =~ ~s|rel="stylesheet"|
    assert html =~ ~s|href="/assets/app.css"|
  end

  test "and carries phx-track-static, so a digested asset is versioned" do
    Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")

    {:ok, _view, html} = live(build_conn(), @path)

    assert html =~ "phx-track-static"
  end

  test "with none configured, no empty link is emitted" do
    # a `<link href="">` would 404 on every page load; better to render nothing
    # and let the host notice an unstyled page
    Application.put_env(:reactive_dag_dashboard, :css_path, nil)

    {:ok, _view, html} = live(build_conn(), @path)

    refute html =~ ~s|rel="stylesheet"|
  end

  test "the page still renders without it — unstyled, not broken" do
    Application.put_env(:reactive_dag_dashboard, :css_path, nil)

    {:ok, _view, html} = live(build_conn(), @path)

    assert html =~ "reactive_dag"
  end

  describe ":root_layout — the host's own chrome" do
    test "a host layout replaces the dashboard's entirely" do
      # the moduledoc has always said this is overridable; it was hardcoded, so
      # a host mounting inside its own shell had no way to say so
      {:ok, _view, html} = live(build_conn(), "/admin/dag")

      assert html =~ "my admin nav"
      assert html =~ ~s|href="/host/app.css"|
    end

    test "and the dashboard's own chrome is not also rendered" do
      # two <head>s, or the dashboard's stylesheet fighting the host's, is the
      # failure mode of getting this half-right
      Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")

      {:ok, _view, html} = live(build_conn(), "/admin/dag")

      refute html =~ ~s|href="/assets/app.css"|
    end

    test "the page itself renders the same either way" do
      {:ok, _view, html} = live(build_conn(), "/admin/dag")

      assert html =~ "sources"
    end
  end
end
