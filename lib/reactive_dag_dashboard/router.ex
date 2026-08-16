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
    * `:root_layout` — a `{module, template}` tuple replacing the dashboard's own
      chrome. Use it when mounting inside an existing admin shell that already
      has a `<head>`, a nav bar and its stylesheet linked.

  ## Styling

  The page is built with daisyUI class names and ships no CSS, so the host's
  stylesheet has to reach it. Two ways, matching the two shapes above:

      # the dashboard's own chrome, told where the CSS lives
      config :reactive_dag_dashboard, css_path: "/assets/app.css"

      # or your chrome, which already links it
      reactive_dag_dashboard "/dag", plan: {MyApp.Dag, :plan, []},
        root_layout: {MyAppWeb.Layouts, :admin}

  Tailwind also has to COMPILE those classes, which means telling it to look
  inside this dependency:

      @source "../deps/reactive_dag_dashboard";
  """
  defmacro reactive_dag_dashboard(path, opts \\ []) do
    quote bind_quoted: binding() do
      plan_mfa = Keyword.fetch!(opts, :plan)
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
          session: %{"plan_mfa" => plan_mfa},
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
