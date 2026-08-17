defmodule ReactiveDagDashboard.Layouts do
  @moduledoc """
  The dashboard's root layout.

  **The host provides the CSS.** This page is built with daisyUI class names —
  `table`, `badge`, `card`, `stat`, `tabs` — and ships none of them, so it
  inherits the host's theme and looks like the rest of their admin rather than
  like a bolted-on tool.

      # the host's app.css
      @import "tailwindcss";
      @plugin "daisyui";

  That is a real requirement, not a nicety: a host without daisyUI gets an
  unstyled page rather than a degraded one. It used to ship its own inline CSS
  for exactly that reason — mounting never touched the host's assets — and the
  trade was a dashboard that could never match the app around it, and a
  hand-maintained stylesheet growing a component at a time.

  ## Getting the assets onto the page

  This layout links the host's compiled CSS, named in config:

      config :reactive_dag_dashboard,
        css_path: "/assets/app.css",
        js_path: "/assets/app.js"

  BOTH are needed. Without the CSS the page is unstyled; without the JS the
  LiveSocket never connects, so the page is static HTML and nothing on it is
  clickable — and from a browser those two look the same ("the dashboard is
  broken"), which is why they were reported as separate bugs.

  Read at RENDER time rather than taken as an assign: `:root_layout` is a
  `{module, template}` tuple with no slot for assigns, so a root layout cannot
  be handed a value through the router. Config is the only channel that reaches
  here.

  Without it the page renders unstyled — which is what shipped in the first
  version of this: the layout tested `assigns[:css_path]`, nothing ever put it
  there, and no option existed to (u2i/reactive_dag_dashboard#18).

  A host mounting inside its own authenticated scope usually wants its own
  chrome instead — a nav bar, a user menu. Pass `:root_layout` to
  `reactive_dag_dashboard/2` and this layout is never used.
  """
  use Phoenix.Component

  @doc """
  The host's stylesheet path, or `nil`.

  A function rather than an assign because a root layout has no assigns to
  receive one through.
  """
  def css_path, do: Application.get_env(:reactive_dag_dashboard, :css_path)

  @doc """
  The host's JavaScript bundle, or `nil`.

  Without it the LiveSocket never connects and the page is STATIC HTML — it
  renders, it looks right, and every `phx-click` on it is inert. Which is most
  of the page: selecting a node, toggling direction, running a scan or a
  reprocess.
  """
  def js_path, do: Application.get_env(:reactive_dag_dashboard, :js_path)

  @doc """
  Which required asset paths are unset, as strings — `[]` when both are there.

  A page that needs configuration to work should SAY so, rather than rendering
  a dead interface and leaving a reader to diagnose it from the source. Both
  failures look identical from a browser ("the dashboard is broken") and both
  were reported as bugs against this library before anyone reached the config
  (u2i/reactive_dag_dashboard#18, #21).

  Nothing is guessed or defaulted: the dashboard cannot know where a host's
  bundles live, and inventing `/assets/app.js` would 404 for anyone whose
  layout differs. It can only be explicit about needing to be told.
  """
  @spec missing() :: [String.t()]
  def missing do
    [{"css_path", css_path()}, {"js_path", js_path()}]
    |> Enum.reject(fn {_name, value} -> value end)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> nil
      names -> names
    end
  end

  @doc "The config a host has to add, ready to paste."
  @spec config_snippet() :: String.t()
  def config_snippet do
    """
    config :reactive_dag_dashboard,
      css_path: "/assets/app.css",
      js_path: "/assets/app.js"\
    """
  end

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>reactive_dag</title>
        <link :if={css_path()} phx-track-static rel="stylesheet" href={css_path()} />
        <script :if={js_path()} defer phx-track-static type="text/javascript" src={js_path()}>
        </script>
        <style>
          /* The SVG graph.

             `currentColor` throughout, and NO daisyUI colour tokens: v5 moved
             them to OKLCH values that already include the colour function, so
             the v4 `hsl(var(--b1))` spelling silently produces an invalid fill
             and SVG falls back to BLACK — which is what the first version of
             this drew, solid black boxes swallowing their own labels.
             `currentColor` inherits whatever the theme set on the container and
             cannot be wrong. */
          .rdd-graph { color: inherit }

          /* a VALUE — rows that exist. Rounded, outlined, transparent. */
          .rdd-gbox { fill: none; stroke: currentColor; stroke-opacity: .3; cursor: pointer }
          .rdd-gbox:hover { stroke-opacity: .75 }
          .rdd-gbox-on { stroke-opacity: 1; stroke-width: 2 }

          /* an OPERATION — a rotated square. One shape for every operator: the
             flavour is the label beside it, not the geometry. */
          .rdd-gop { fill: none; stroke: currentColor; stroke-opacity: .45; cursor: pointer }
          .rdd-gop:hover { stroke-opacity: .9 }
          .rdd-gop-on { stroke-opacity: 1; stroke-width: 2 }

          /* a set, not a single row — the stacked-card glyph */
          .rdd-gstack { fill: none; stroke: currentColor; stroke-opacity: .15 }

          .rdd-edge { stroke: currentColor; stroke-width: 1.2; opacity: .3; fill: none }
          .rdd-edge-hot { opacity: .95; stroke-width: 2 }

          .rdd-gtext { font-size: 11.5px; font-weight: 500; fill: currentColor }
          .rdd-gsub { font-size: 9.5px; fill: currentColor; opacity: .55;
                      font-variant-numeric: tabular-nums }
          .rdd-goplabel { font-size: 9.5px; fill: currentColor; opacity: .7;
                          font-family: ui-monospace, monospace }
          .rdd-gband { font-size: 9px; fill: currentColor; opacity: .35;
                       letter-spacing: .08em; text-transform: uppercase }
          .rdd-gbandline { stroke: currentColor; opacity: .1; stroke-width: 1 }

          /* ── the expression tree ────────────────────────────────────────

             A node is a bordered CARD, not an indented row: containment reads
             as structure where a margin does not, and a subtree becomes a
             visible region of the page. `currentColor` again throughout, for
             the same reason the SVG uses it — daisyUI v5 tokens are OKLCH and
             the v4 spelling silently resolves to black. */
          /* The stacked-card glyph needs an OPAQUE ground between its layers,
             or the four shadows composite into one smear. daisyUI v5 exposes
             the base colour as a plain custom property holding a complete
             colour value — used bare, never wrapped in hsl(), which is the v4
             spelling that resolves to nothing. The fallback keeps the glyph
             legible on a host that themes differently. */
          .rdd-tree { --rdd-indent: 26px; --rdd-ground: var(--color-base-100, Canvas) }

          .rdd-row {
            display: flex; align-items: baseline; gap: .5rem;
            position: relative; overflow: hidden;
            padding: 7px 11px; margin-bottom: 4px;
            border: 1px solid currentColor; border-color: color-mix(in oklab, currentColor 18%, transparent);
            border-radius: 9px;
            background: var(--rdd-panel, transparent);
          }
          .rdd-row:hover { border-color: color-mix(in oklab, currentColor 38%, transparent) }
          .rdd-on { border-color: color-mix(in oklab, currentColor 65%, transparent);
                    background: color-mix(in oklab, currentColor 7%, transparent) }

          /* the kind spine: where data ENTERS, where it is COMBINED, where it
             is merely carried. Three, because the library has three. */
          .rdd-lead { position: absolute; left: 0; top: 0; bottom: 0; width: 4px;
                      border-radius: 9px 0 0 9px }
          .rdd-lead-source { background: color-mix(in oklab, currentColor 55%, transparent) }
          .rdd-lead-join   { background: color-mix(in oklab, currentColor 40%, transparent) }
          .rdd-lead-derive { background: color-mix(in oklab, currentColor 22%, transparent) }
          .rdd-lead-plain  { background: color-mix(in oklab, currentColor 12%, transparent) }

          /* a set, not a single row — the stacked-card glyph, matching the SVG.
             Drawn with borders rather than a shadow so it reads on either
             theme without a colour that only works on one ground. */
          .rdd-many {
            box-shadow:
              3px 3px 0 0 var(--rdd-ground, transparent),
              4px 4px 0 0 color-mix(in oklab, currentColor 18%, transparent),
              6px 6px 0 0 var(--rdd-ground, transparent),
              7px 7px 0 0 color-mix(in oklab, currentColor 18%, transparent);
            margin-bottom: 12px;
          }

          .rotate-90 { transform: rotate(90deg) }
        </style>
      </head>
      <body>
        <div :if={missing()} class="alert alert-warning m-4" role="alert">
          <div>
            <p class="font-semibold">
              reactive_dag_dashboard is missing <%= Enum.join(missing(), " and ") %>.
            </p>
            <p class="text-sm">
              Without <code>js_path</code> the LiveSocket never connects, so nothing on this
              page is clickable. Without <code>css_path</code> it renders unstyled.
            </p>
            <pre class="text-xs mt-2"><code><%= config_snippet() %></code></pre>
          </div>
        </div>

        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
