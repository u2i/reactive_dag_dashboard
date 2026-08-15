ExUnit.start()

Application.put_env(:reactive_dag_dashboard, ReactiveDagDashboard.TestEndpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "testsalt"],
  server: false,
  secret_key_base: String.duplicate("a", 64)
)

Application.put_env(:reactive_dag_dashboard, :pubsub, ReactiveDagDashboard.TestPubSub)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: ReactiveDagDashboard.TestPubSub)
{:ok, _} = ReactiveDagDashboard.TestEndpoint.start_link()
