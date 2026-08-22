defmodule ReactiveDagDashboard.TestRouter do
  @moduledoc """
  Mounts the dashboard the way a host does — through the public router macro,
  and at a NESTED path, so the tests cover the mount point a real app uses
  rather than the root case that happens to work by accident.
  """
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import ReactiveDagDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    reactive_dag_dashboard("/ops/dag", plan: {ReactiveDagDashboard.FixtureGraph, :plan, []})

    # a second mount with the host's OWN chrome, the shape an app uses when the
    # dashboard sits inside an existing admin shell that already has a <head>
    reactive_dag_dashboard("/admin/dag",
      plan: {ReactiveDagDashboard.FixtureGraph, :plan, []},
      as: :host_chrome,
      live_session_name: :host_chrome,
      root_layout: {ReactiveDagDashboard.HostLayout, :root}
    )

    # a MULTI-TENANT mount: the same topology, several graphs
    reactive_dag_dashboard("/multi/dag",
      plan: {ReactiveDagDashboard.FixtureGraph, :plan, []},
      tenants: {ReactiveDagDashboard.FixtureGraph, :tenants, []},
      as: :multi,
      live_session_name: :multi
    )
  end
end

defmodule ReactiveDagDashboard.HostLayout do
  @moduledoc "A host's own chrome, for the `:root_layout` override test."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>my admin</title>
        <link rel="stylesheet" href="/host/app.css" />
      </head>
      <body>
        <nav>my admin nav</nav>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
