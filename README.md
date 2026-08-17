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

## Styling: none required

The dashboard ships its own CSS — about 200 lines, scoped to `.rdd`, rendered by
the page itself. No Tailwind, no theme, no stylesheet to link. It is styled
wherever you mount it and under whichever layout, including your own.

One setting, and it is about JavaScript:

```elixir
config :reactive_dag_dashboard, js_path: "/assets/app.js"
```

Without it the LiveSocket never connects, so the page is static HTML and nothing
on it is clickable — no selecting a node, no direction toggle, no scan or
reprocess buttons.

If the dashboard sits inside an admin shell that already has a `<head>` and
loads its own JS, give it your chrome and configure nothing:

```elixir
reactive_dag_dashboard "/admin/dag",
  plan: {MyApp.Dag, :plan, []},
  root_layout: {MyAppWeb.Layouts, :admin}
```

`css_path:` is still honoured if you set it — a hook for layering a font or a
colour override on top. It is no longer required.

### Why it stopped using daisyUI

It was built on daisyUI so it would inherit your theme and look like the rest of
your admin. That never worked — a design that adapts to any theme commits to
none — and it cost three configuration steps that each failed as a page that
looked plausible and was subtly broken: link a stylesheet, point Tailwind at this
dependency so the classes were compiled at all, and keep the dashboard's own root
layout or lose its component rules.

Owning the CSS removes all three. The trade is that the dashboard looks like
itself, which is what it was doing anyway.


## Installation

```elixir
def deps do
  [
    {:reactive_dag, "~> 0.17.0-rc.18"},
    {:reactive_dag_dashboard, "~> 0.1"}
  ]
end
```

The `reactive_dag` requirement is a range over the 0.17 rc series. `~>` on a
pre-release does resolve later pre-releases, so this tracks rc.19+ and the 0.17.0
final without a bump here, while holding 0.18 for a deliberate one. The floor is
rc.18 because that is where the drain step gained `op`/`depth`; the dashboard
needs the drain telemetry that landed back in rc.6.

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

## Live updates

Without any further wiring the page **polls** every few seconds, which works and
is visibly labelled as such. To make it live, point the dashboard at your PubSub
and attach the observer once at boot:

```elixir
# config
config :reactive_dag_dashboard, pubsub: MyApp.PubSub

# application.ex, after the supervision tree is up
ReactiveDagDashboard.Observer.attach(MyApp.PubSub)
```

That attaches a `:telemetry` handler to the drain's events and rebroadcasts them,
so every open dashboard sees each drain as it happens. The header says `live`
rather than `polling` once it is working.

**It refreshes only what moved.** A drain step names the cell it recomputed, so
the page re-reads that cell rather than the graph — per-cell state is one query
each, and re-reading forty of them per step would cost more than the work being
observed. The poll timer stays as a fallback (slower when live), because a page
that silently froze would be worse than a slow one.

The handler runs inside the drain's process and does nothing but copy a few
fields into a message, so watching the dashboard cannot slow the engine down. A
broadcast failure is logged and swallowed for the same reason: an unreachable
dashboard must not be able to fail a drain.

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
