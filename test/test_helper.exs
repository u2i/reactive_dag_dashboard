ExUnit.start()

Application.put_env(:reactive_dag_dashboard, ReactiveDagDashboard.TestEndpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "testsalt"],
  server: false,
  secret_key_base: String.duplicate("a", 64)
)

{:ok, _} = ReactiveDagDashboard.TestEndpoint.start_link()
