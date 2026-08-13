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
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    reactive_dag_dashboard("/ops/dag", plan: {ReactiveDagDashboard.FixtureGraph, :plan, []})
  end
end
