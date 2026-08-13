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
  └─ ReactiveDag.Insights          ← queries: plan structure, per-cell state,
                                      retained reports (no UI dependencies;
                                      useful without Phoenix)

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

`Drain.run/2` returns a `%Report{}` and most callers discard it — the drain
deliberately persists nothing (the library reports; the host records). To see
the trace, hand each report to `Insights.record/1`:

```elixir
{:ok, report} = ReactiveDag.Drain.run(plan, opts)
ReactiveDag.Insights.record(report)
```

That keeps the last N in ETS (`config :reactive_dag, insights_keep: 20`), which
is an opt-in observer rather than a durable log: per-node, in memory, lost on
restart. A host that needs history stores the report where its runs already live.

Without it the dashboard still renders structure and per-cell state — the trace
panel simply does not appear.

## Status

**Early.** See the [tracking issue](https://github.com/u2i/reactive_dag/issues/41)
for scope and open questions. Nothing here is stable yet.

## License

MIT
