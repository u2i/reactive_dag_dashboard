defmodule ReactiveDagDashboard.Router do
  @moduledoc """
  Mounts the dashboard in a host's router.

  The macro deliberately does **no** authentication — it defines a `live_session`
  and a route, and nothing else. Mount it inside whatever pipeline already
  protects your admin surface; a dashboard that shipped its own auth would either
  duplicate the host's or quietly weaken it.

      import ReactiveDagDashboard.Router

      scope "/admin" do
        pipe_through [:browser, :require_admin]

        reactive_dag_dashboard "/reactive-dag",
          plan: {MyApp.Dag, :plan, []}
      end
  """

  @doc """
  Define the dashboard routes at `path`.

  Options:

    * `:plan` — **required**. An MFA (`{module, function, args}`) returning the
      `%ReactiveDag.Plan{}` to display; usually the same call the drain uses.
      An MFA rather than a plan value because a plan is built at runtime from
      resource modules, and rebuilding it per request keeps the page honest when
      the graph changes.
    * `:as` — the route name (default `:reactive_dag_dashboard`).
    * `:live_session_name` — default `:reactive_dag_dashboard`.
    * `:on_mount` — extra `on_mount` hooks for the live session, so a host can
      assign its current user or enforce a role inside the LiveView too.
  """
  defmacro reactive_dag_dashboard(path, opts \\ []) do
    quote bind_quoted: binding() do
      plan_mfa = Keyword.fetch!(opts, :plan)
      session_name = Keyword.get(opts, :live_session_name, :reactive_dag_dashboard)
      route_name = Keyword.get(opts, :as, :reactive_dag_dashboard)
      extra_on_mount = List.wrap(Keyword.get(opts, :on_mount, []))

      scope path, alias: false, as: false do
        live_session session_name,
          root_layout: {ReactiveDagDashboard.Layouts, :root},
          session: %{"plan_mfa" => plan_mfa},
          on_mount: extra_on_mount do
          live("/", ReactiveDagDashboard.PageLive, :index, as: route_name)
          live("/cell/:cell_id", ReactiveDagDashboard.PageLive, :cell, as: route_name)

          # the two directional views. `/from/:id` answers "a change here goes
          # WHERE"; `/into/:id` answers "this table is fed by WHAT". Both are
          # the same expansion with the edge index reversed.
          live("/from", ReactiveDagDashboard.TreeLive, :downstream, as: route_name)
          live("/from/:cell_id", ReactiveDagDashboard.TreeLive, :downstream, as: route_name)
          live("/into", ReactiveDagDashboard.TreeLive, :upstream, as: route_name)
          live("/into/:cell_id", ReactiveDagDashboard.TreeLive, :upstream, as: route_name)
        end
      end
    end
  end
end
