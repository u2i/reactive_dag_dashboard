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
    prev_js = Application.get_env(:reactive_dag_dashboard, :js_path)

    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)

    on_exit(fn ->
      Application.put_env(:reactive_dag, :repo, prev_repo)
      Application.put_env(:reactive_dag_dashboard, :css_path, prev_css)
      Application.put_env(:reactive_dag_dashboard, :js_path, prev_js)
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

  describe "the JS bundle — without it, nothing is clickable" do
    # The page is `phx-click` throughout: selecting a node, toggling direction,
    # running a scan or a reprocess. With no <script> the LiveSocket never
    # connects, so it renders, looks right, and does nothing — which reads as
    # "the dashboard only knows about one source" (u2i/reactive_dag_dashboard#21).
    test "the configured bundle is loaded" do
      Application.put_env(:reactive_dag_dashboard, :js_path, "/assets/app.js")

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ ~s|src="/assets/app.js"|
    end

    test "deferred, so it does not block the first paint" do
      Application.put_env(:reactive_dag_dashboard, :js_path, "/assets/app.js")

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "defer"
      assert html =~ "phx-track-static"
    end

    test "with none configured, no empty script tag is emitted" do
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      refute html =~ "<script"
    end

    test "the page still renders without it — static, not broken" do
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "reactive_dag"
    end

    test "CSS and JS are independent — one configured, the other not" do
      # they were reported as separate bugs because from a browser both look
      # like "the dashboard is broken"
      Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ ~s|href="/assets/app.css"|
      refute html =~ "<script"
    end
  end

  describe "missing config announces itself" do
    # A page that needs configuration to work should SAY so. Both failures look
    # identical from a browser — "the dashboard is broken" — and both were filed
    # as library bugs before anyone reached the config (#18, then #21). The
    # second was diagnosed from source twice before the page was opened.
    test "an unset js_path is named on the page" do
      Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "missing js_path"
      assert html =~ "LiveSocket never connects", "says what breaks, not just what is unset"
    end

    test "an unset css_path is NOT a warning — the dashboard ships its own CSS" do
      # it was required when the page was built from daisyUI class names it did
      # not ship. Warning about an optional override would be crying wolf, and
      # the page below proves it is genuinely styled without one.
      Application.put_env(:reactive_dag_dashboard, :css_path, nil)
      Application.put_env(:reactive_dag_dashboard, :js_path, "/assets/app.js")

      {:ok, _view, html} = live(build_conn(), @path)

      refute html =~ "missing css_path"
      refute html =~ "is missing"
      assert html =~ ".rdd-row", "and it is styled anyway"
    end

    test "only js_path is named when both are unset" do
      Application.put_env(:reactive_dag_dashboard, :css_path, nil)
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "missing js_path"
      refute html =~ "css_path and js_path"
    end

    test "and it carries the config to paste" do
      Application.put_env(:reactive_dag_dashboard, :css_path, nil)
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), @path)

      assert html =~ "config :reactive_dag_dashboard"
      assert html =~ "js_path:"
    end

    test "with both configured, nothing is said" do
      Application.put_env(:reactive_dag_dashboard, :css_path, "/assets/app.css")
      Application.put_env(:reactive_dag_dashboard, :js_path, "/assets/app.js")

      {:ok, _view, html} = live(build_conn(), @path)

      refute html =~ "alert-warning"
    end

    test "a host with its own root_layout is not nagged" do
      # they supply their own <head>; this layout is never used
      Application.put_env(:reactive_dag_dashboard, :css_path, nil)
      Application.put_env(:reactive_dag_dashboard, :js_path, nil)

      {:ok, _view, html} = live(build_conn(), "/admin/dag")

      refute html =~ "alert-warning"
    end
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

      assert html =~ "expression"
    end

    test "the component styles survive the override" do
      # THE BUG: these rules lived only in this library's `Layouts.root/1`, so a
      # host passing `root_layout:` — which the docs recommend — silently lost
      # every one of them. The page kept its daisyUI classes and still looked
      # styled, while the expression tree lost its cards and spines and the SVG
      # rendered with no fills or strokes at all. Diagnosing that means knowing
      # the CSS lived in a layout you replaced.
      #
      # Asserted on RULES, not on the presence of a <style> tag: a host layout
      # may have one of its own, so an empty block would pass that.
      {:ok, _view, html} = live(build_conn(), "/admin/dag")

      assert html =~ ".rdd-row", "the tree's cards"
      assert html =~ ".rdd-source > .rdd-row > .rdd-lead", "the kind spine"
      assert html =~ ".rdd-gbox", "the graph's boxes"
      assert html =~ ".rdd-children", "the nesting rail"
    end

    test "and they are identical to what the dashboard's own layout serves" do
      # the two mounts must not drift into two looks — the point of moving these
      # to the page is that there IS only one copy
      {:ok, _view, own} = live(build_conn(), "/ops/dag")
      {:ok, _view, host} = live(build_conn(), "/admin/dag")

      assert styles_of(own) == styles_of(host)
      refute styles_of(own) == "", "a passing comparison of two empty strings proves nothing"
    end

    test "the rules are served once, not once per layer" do
      # the dashboard's own layout deliberately does not repeat them: the page
      # it wraps already carries them, and a second copy is one to keep in step
      {:ok, _view, html} = live(build_conn(), "/ops/dag")

      # anchored at line start, so `.rdd-many > .rdd-row {` does not count as a
      # second definition of `.rdd-row` itself
      assert length(Regex.scan(~r/^\s*\.rdd-row \{/m, html)) == 1
    end
  end

  # The PAGE's stylesheet only. This library's own layout carries a small
  # `<style>` of its own for the document ground and the missing-config warning
  # — which must not depend on the page's CSS, since it fires when the page is
  # broken — and matching `.rdd-` alone would sweep that in.
  defp styles_of(html) do
    ~r/<style>(.*?)<\/style>/s
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&(&1 =~ ".rdd-row"))
    |> Enum.join()
    |> String.trim()
  end
end
