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

  For a host running the same graph for several tenants, name the tenant list too
  — the dashboard renders a switch and asks `:plan` for one tenant at a time:

      reactive_dag_dashboard "/reactive-dag",
        plan: {MyApp.Dag, :plan, []},
        tenants: {MyApp.Municipalities, :for_dashboard, []}
  """

  @doc """
  Define the dashboard routes at `path`.

  Options:

    * `:plan` — **required**. An MFA (`{module, function, args}`) returning the
      `%ReactiveDag.Plan{}` to display; usually the same call the drain uses.
      An MFA rather than a plan value because a plan is built at runtime from
      resource modules, and rebuilding it per request keeps the page honest when
      the graph changes.
    * `:tenants` — an MFA returning this host's tenants, when the same topology
      runs for several of them (`ReactiveDag.Node.graph(resources, tenant: t)`).
      Each entry is `{id, label}` or a bare id. The dashboard renders a switch
      above everything else and calls `:plan`'s function with the chosen id
      APPENDED to its args, so `plan: {MyApp.Dag, :plan, []}` becomes
      `MyApp.Dag.plan("tenant_a")`.

      An MFA, like `:plan`, because a tenant list is data that changes without a
      deploy — a literal would freeze at compile time and go stale the first time
      one is added. Omit it for a host running one graph and the page is exactly
      as it was.
    * `:as` — the route name (default `:reactive_dag_dashboard`).
    * `:live_session_name` — default `:reactive_dag_dashboard`.
    * `:on_mount` — extra `on_mount` hooks for the live session, so a host can
      assign its current user or enforce a role inside the LiveView too.
    * `:root_layout` — a `{module, template}` tuple replacing the dashboard's own
      chrome. Use it when mounting inside an existing admin shell that already
      has a `<head>`, a nav bar and its stylesheet linked.

  ## Styling

  Nothing to do. The dashboard ships its own CSS, scoped to `.rdd` and rendered
  by the page, so it is styled wherever it is mounted and under whichever
  layout — including your own.

  It used to be built from daisyUI class names it did not ship, which meant a
  host had to link a stylesheet, point Tailwind at this dependency so those
  classes were compiled, and keep the dashboard's own root layout. Each of
  those failed as a page that looked plausible and was subtly broken.

  ## What you DO configure

  One thing, and it is JavaScript:

      config :reactive_dag_dashboard, js_path: "/assets/app.js"

  Without it the LiveSocket never connects and nothing on the page is
  clickable. A host passing its own `:root_layout` already loads its own JS and
  needs no setting at all.
  """
  defmacro reactive_dag_dashboard(path, opts \\ []) do
    quote bind_quoted: binding() do
      plan_mfa = Keyword.fetch!(opts, :plan)
      tenants_mfa = Keyword.get(opts, :tenants)
      session_name = Keyword.get(opts, :live_session_name, :reactive_dag_dashboard)
      route_name = Keyword.get(opts, :as, :reactive_dag_dashboard)
      extra_on_mount = List.wrap(Keyword.get(opts, :on_mount, []))

      # The moduledoc has always said this is overridable; it was hardcoded, so
      # a host mounting inside its own chrome had no way to say so
      # (u2i/reactive_dag_dashboard#18).
      layout = Keyword.get(opts, :root_layout, {ReactiveDagDashboard.Layouts, :root})

      scope path, alias: false, as: false do
        live_session session_name,
          root_layout: layout,
          session: %{"plan_mfa" => plan_mfa, "tenants_mfa" => tenants_mfa},
          on_mount: extra_on_mount do
          # ONE view. It used to be three — an index by depth plus the two
          # directional trees — each answering a slice of the same question and
          # none of them alone: you found a cell on the index, went to /from to
          # see what it reached, then back to read what it held.
          live("/", ReactiveDagDashboard.DagLive, :index, as: route_name)
          live("/cell/:cell_id", ReactiveDagDashboard.DagLive, :cell, as: route_name)
        end
      end
    end
  end
end
