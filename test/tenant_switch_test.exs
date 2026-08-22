defmodule ReactiveDagDashboard.TenantSwitchTest do
  @moduledoc """
  The tenant switch: when a host names `tenants:`, the page shows one graph at a
  time and switches between them ABOVE the funnel.

  The page below the switch is a narrowing sequence — which question, which cell,
  which view. A tenant is not a narrowing of any of that: it chooses which GRAPH
  the sequence is about. So it sits outside, and these tests pin that rather than
  merely that a control exists.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ReactiveDagDashboard.FixtureGraph

  @endpoint ReactiveDagDashboard.TestEndpoint
  @multi "/multi/dag"
  @single "/ops/dag"

  setup do
    start_supervised!(%{
      id: ReactiveDagDashboard.FakeRepo,
      start: {ReactiveDagDashboard.FakeRepo, :start_link, []}
    })

    prev = Application.get_env(:reactive_dag, :repo)
    Application.put_env(:reactive_dag, :repo, ReactiveDagDashboard.FakeRepo)
    FixtureGraph.seed()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:reactive_dag, :repo, prev),
        else: Application.delete_env(:reactive_dag, :repo)
    end)

    :ok
  end

  describe "a host with no tenants" do
    test "renders no switch at all" do
      {:ok, _view, html} = live(build_conn(), @single)

      refute html =~ ~s(class="rdd-tenants"),
             "a host running one graph must see the page exactly as before"
    end

    test "and its plan is built with no tenant argument" do
      # `plan/0`, not `plan/1` — an untenanted host declares `plan: {M, :plan, []}`
      # and nothing appends to it.
      {:ok, _view, html} = live(build_conn(), @single)
      assert html =~ "expenses"
    end
  end

  describe "the switch" do
    test "renders one button per declared tenant, using the host's labels" do
      {:ok, _view, html} = live(build_conn(), @multi)

      assert html =~ ~s(class="rdd-tenants")
      assert html =~ "Borough of Test"
      assert html =~ "Village of Test"
    end

    test "sits OUTSIDE the funnel, not inside any of its rows" do
      {:ok, _view, html} = live(build_conn(), @multi)

      # it precedes the first funnel row in the document...
      [before_ask, _] = String.split(html, ~s(<div class="rdd-ask">), parts: 2)
      assert before_ask =~ ~s(class="rdd-tenants"), "the switch comes before the funnel"

      # ...and appears in none of the funnel's three rows
      for {region, opener} <- [
            {"the direction pair", ~s(<div class="rdd-ask">)},
            {"the cell picker", ~s(<div class="rdd-starts">)},
            {"the view bar", ~s(<div class="rdd-bar">)}
          ] do
        assert String.contains?(html, opener), "#{region} vanished; update this test"
        [_, region_html] = String.split(html, opener, parts: 2)

        refute region_html |> String.split("</div>", parts: 2) |> hd() =~ "rdd-tenant",
               "a tenant is not a narrowing inside #{region}"
      end
    end

    test "the first tenant is selected by default" do
      {:ok, _view, html} = live(build_conn(), @multi)

      [_, first] = String.split(html, ~s(class="rdd-tenant on"), parts: 2)
      assert first =~ "Borough of Test", "the first declared tenant is the default"
    end

    test "a tenant named in the URL is the one selected" do
      {:ok, _view, html} = live(build_conn(), "#{@multi}?tenant=village")

      [_, selected] = String.split(html, ~s(class="rdd-tenant on"), parts: 2)
      assert selected =~ "Village of Test"
    end

    test "and the LOADED PLAN is that tenant's, not merely the button" do
      # The claim the whole feature rests on: the tenant reaches the host's plan
      # builder. Asserting the highlighted button only proves the click was
      # recorded — the plan could still be the default's.
      # `render/1`, not the mount's html: the static render happens before
      # `handle_params`, so the tenant is not resolved in it yet.
      {:ok, view, _} = live(build_conn(), "#{@multi}?tenant=village")
      assert render(view) =~ ~s(data-tenant="village")

      {:ok, view, _} = live(build_conn(), "#{@multi}?tenant=borough")
      assert render(view) =~ ~s(data-tenant="borough")
    end

    test "switching RELOADS the plan for the new tenant" do
      {:ok, view, _} = live(build_conn(), "#{@multi}?tenant=borough")
      assert render(view) =~ ~s(data-tenant="borough")

      view |> element(~s(button[phx-value-to="village"])) |> render_click()

      assert render(view) =~ ~s(data-tenant="village"),
             "the plan followed the switch"
    end

    test "an UNKNOWN tenant falls back rather than reaching the host's builder" do
      # A typo'd or stale URL must render a graph. Passing the id through would
      # reach `plan/1`, which has no reason to expect it.
      {:ok, _view, html} = live(build_conn(), "#{@multi}?tenant=nope")

      [_, selected] = String.split(html, ~s(class="rdd-tenant on"), parts: 2)
      assert selected =~ "Borough of Test"
    end
  end

  describe "switching" do
    test "puts the tenant in the URL, so a link carries it" do
      {:ok, view, _html} = live(build_conn(), @multi)

      view |> element(~s(button[phx-value-to="village"])) |> render_click()

      assert_patched(view, "/multi/dag?direction=downstream&tenant=village")
    end

    test "clears the selected cell" do
      # Cell ids REPEAT across tenants, so the same id usually exists in both.
      # Carrying it over would show a different tenant's data under a name the
      # reader already had on screen.
      {:ok, view, _html} = live(build_conn(), "#{@multi}?tenant=borough")

      view |> element(~s(button[phx-value-cell="expenses"])) |> render_click()
      assert render(view) =~ "rdd-row"

      view |> element(~s(button[phx-value-to="village"])) |> render_click()

      assert_patched(view, "/multi/dag?direction=downstream&tenant=village")
    end

    test "keeps the DIRECTION — a question survives, a place does not" do
      {:ok, view, _html} = live(build_conn(), "#{@multi}?direction=upstream")

      view |> element(~s(button[phx-value-to="village"])) |> render_click()

      assert_patched(view, "/multi/dag?direction=upstream&tenant=village")
    end
  end

  describe "the tenant rides in every link" do
    test "a cell link keeps the tenant" do
      {:ok, view, _html} = live(build_conn(), "#{@multi}?tenant=village")

      view |> element(~s(button[phx-value-cell="expenses"])) |> render_click()

      # the patch target carries `tenant=village`, so a copied URL shows the same
      # graph — without this, clicking a cell silently reverts to the default
      assert_patch(view) =~ "tenant=village"
    end

    test "a view change keeps the tenant" do
      {:ok, view, _html} = live(build_conn(), "#{@multi}?tenant=village")

      view |> element(~s(button[phx-value-to="log"])) |> render_click()

      assert_patch(view) =~ "tenant=village"
    end
  end

  describe "a view with no cell selected (pre-existing bug, fixed here)" do
    test "the `runs` view is reachable before picking a cell" do
      # `path_for/2` built `cell/` with an empty id, which is not a route, so
      # `push_patch` raised. It broke on the ONE view deliberately reachable
      # without a cell — found while testing the tenant switch, and present on
      # the untenanted mount too.
      {:ok, view, _html} = live(build_conn(), @single)

      view |> element(~s(button[phx-value-to="log"])) |> render_click()

      assert render(view) =~ "rdd-log"
    end

    test "...and on a tenanted mount it keeps the tenant" do
      {:ok, view, _html} = live(build_conn(), "#{@multi}?tenant=village")

      view |> element(~s(button[phx-value-to="log"])) |> render_click()

      target = assert_patch(view)

      assert target =~ "tenant=village"
      refute target =~ "cell/", "no empty cell segment — that is what raised"
    end
  end

  describe "the plan actually differs" do
    test "each tenant's plan carries its own tenant" do
      # The switch is only meaningful if it changes which graph is loaded. This
      # asserts the library-side fact the page depends on.
      assert FixtureGraph.plan("borough").tenant == "borough"
      assert FixtureGraph.plan("village").tenant == "village"
      assert FixtureGraph.plan().tenant == "*"
    end

    test "but the topology is identical" do
      a = FixtureGraph.plan("borough")
      b = FixtureGraph.plan("village")

      assert Map.keys(a.cells) == Map.keys(b.cells)
      assert a.depths == b.depths
    end
  end
end
