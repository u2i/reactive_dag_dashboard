# reactive_dag_dashboard

A graph status dashboard for [reactive_dag](https://github.com/u2i/reactive_dag):
the DAG's **structure**, each cell's **status**, and the last drain's **trace** —
as a Phoenix LiveView you mount inside your own router pipeline.

Answers the three questions a reactive DAG makes you ask at 2am:

- **What is stale or failing?** — per-cell status rollups, with a sample of failing keys.
- **What did the last drain actually do?** — the `%Drain.Report{}` as a waterfall: what was claimed, what changed, what triggered it, how long each step took.
- **Why did *this* node recompute?** — follow `triggered_by` back up the graph.

## Where the logic lives

This package **renders**; it computes nothing itself.

```
reactive_dag
  └─ ReactiveDag.Insights          ← queries: plan structure, status, retained reports
                                      (no UI dependencies; useful without Phoenix)

reactive_dag_dashboard             ← this repo
  └─ router macro + LiveView + graph rendering
```

That split is deliberate. The read API needs library internals and is valuable
to hosts with no Phoenix at all (a mix task, a JSON endpoint, an alert). Keeping
it in the core library also keeps Phoenix and LiveView out of `reactive_dag`'s
dependency tree.

## Installation

```elixir
def deps do
  [
    {:reactive_dag, "~> 0.17"},
    {:reactive_dag_dashboard, "~> 0.1"}
  ]
end
```

Mount it in your router, **inside whatever pipeline already authenticates your
admins** — this package ships no auth of its own, by design:

```elixir
import ReactiveDagDashboard.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  reactive_dag_dashboard "/reactive-dag",
    plan: {MyApp.Dag, :plan, []}      # how to build the %Plan{} to display
end
```

The dashboard needs to know which graph to show. `:plan` names an MFA returning
a `%ReactiveDag.Plan{}` — usually the same call your drain uses.

## Retaining the drain trace

`Drain.run/2` returns a `%Report{}` and most callers discard it. To see the trace,
configure a sink (the default keeps the last N in ETS):

```elixir
config :reactive_dag, report_sink: ReactiveDag.Insights.Buffer
```

Without a sink the dashboard still renders structure and status — the trace panel
simply reports that nothing has been retained.

## Status

**Early.** See the [tracking issue](https://github.com/u2i/reactive_dag/issues/41)
for scope and open questions. Nothing here is stable yet.

## License

MIT
