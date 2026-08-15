defmodule ReactiveDagDashboard.TestEndpoint do
  @moduledoc "A minimal endpoint so the LiveView tests have somewhere to mount."
  use Phoenix.Endpoint, otp_app: :reactive_dag_dashboard

  @session_options [store: :cookie, key: "_rdd_test", signing_salt: "testsalt"]

  plug Plug.Session, @session_options
  plug ReactiveDagDashboard.TestRouter
end
