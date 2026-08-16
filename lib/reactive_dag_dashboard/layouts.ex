defmodule ReactiveDagDashboard.Layouts do
  @moduledoc """
  The dashboard's root layout.

  Self-contained on purpose: the page ships its own minimal CSS inline rather
  than assuming the host's asset pipeline, so mounting the dashboard never
  requires touching the host's `app.css` or esbuild config.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>reactive_dag</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; font: 14px/1.5 ui-sans-serif, system-ui, sans-serif; }
          .rdd { padding: 1.5rem; max-width: 72rem; margin: 0 auto; }
          .rdd h1 { font-size: 1.25rem; margin: 0 0 1rem; }
          .rdd h2 { font-size: .75rem; text-transform: uppercase; letter-spacing: .06em;
                    opacity: .6; margin: 1.25rem 0 .375rem; }
          .rdd ul { list-style: none; margin: 0; padding: 0; display: flex;
                    flex-wrap: wrap; gap: .5rem; }
          .rdd li { border: 1px solid currentColor; border-radius: .375rem;
                    padding: .375rem .625rem; }
          .rdd-badge { font-size: .6875rem; opacity: .6; margin-left: .375rem; }
          .rdd li a { color: inherit; text-decoration: none; }
          .rdd li a:hover { text-decoration: underline; }
          .rdd-count { font-size: .6875rem; opacity: .6; margin-left: .375rem; }
          .rdd-status { font-size: .6875rem; margin-left: .375rem;
                        border: 1px solid currentColor; border-radius: .25rem;
                        padding: 0 .25rem; }
          /* a cell whose rows could not be read — NOT the same as an empty one */
          .rdd-unknown { border-style: dashed; opacity: .55; }
          .rdd-drawer { margin-top: 1.5rem; border: 1px solid currentColor;
                        border-radius: .375rem; padding: .75rem 1rem; }
          .rdd-drawer dl { display: grid; grid-template-columns: max-content 1fr;
                           gap: .125rem .75rem; margin: .5rem 0 0; }
          .rdd-drawer dt { font-size: .6875rem; text-transform: uppercase;
                           letter-spacing: .06em; opacity: .6; }
          .rdd-drawer dd { margin: 0; }
          .rdd-drawer ul, .rdd-report ol { display: block; }
          .rdd-drawer li, .rdd-report li { border: 0; padding: .125rem 0; }
          .rdd-report ol { margin: .25rem 0 0; padding-left: 1.25rem;
                           list-style: decimal; }
          .rdd-cause { opacity: .6; }

          /* ── the two directional views ──────────────────────────────────── */
          .rdd-tabs { display: flex; gap: 1rem; margin-bottom: 1rem;
                      font-size: .8125rem; }
          .rdd-tabs a { color: inherit; opacity: .6; text-decoration: none;
                        padding-bottom: .125rem; }
          .rdd-tabs a:hover { opacity: 1; }
          .rdd-tabs .rdd-active { opacity: 1; font-weight: 600;
                                  border-bottom: 2px solid currentColor; }
          .rdd-picker ul { margin-bottom: .5rem; }
          .rdd-picker .rdd-active { font-weight: 600; text-decoration: underline; }
          .rdd-note { font-weight: 400; text-transform: none; letter-spacing: 0;
                      margin-left: .5rem; }
          .rdd-empty { opacity: .6; }

          /* the tree is a LIST, indented by depth: one row per path step, so a
             cell reached twice occupies two rows. */
          .rdd-tree ol { list-style: none; margin: .25rem 0 0; padding: 0;
                         display: flex; flex-direction: column; gap: .125rem; }
          .rdd-row { display: flex; align-items: center; gap: .375rem;
                     border: 0; padding: .25rem 0;
                     padding-left: calc(var(--indent) * 1.5rem); }
          .rdd-row a { color: inherit; }
          .rdd-rail { width: .75rem; height: 1px; background: currentColor;
                      opacity: .3; flex: none; }
          .rdd-row:first-child .rdd-rail { visibility: hidden; }
          .rdd-via { font-size: .6875rem; opacity: .5; }
          /* a repeat is DIMMED, not hidden — the path is real work, but its
             detail was already read once */
          .rdd-repeat-row { opacity: .55; }
          .rdd-repeat { font-style: italic; }
          .rdd-cyclic-row { color: #b3341f; }
          .rdd-cyclic { font-weight: 600; }

          /* the collapsed shape: one row per cell, banded by distance. Bands
             replace indentation because depth-as-padding stops being readable
             at about three levels, and `via` states parentage anyway. */
          .rdd-band { margin: .5rem 0 1rem; }
          .rdd-band-label { font-size: .6875rem; text-transform: uppercase;
                            letter-spacing: .06em; opacity: .5; margin: 0 0 .375rem;
                            font-weight: 600; }
          .rdd-bands ul { display: flex; flex-wrap: wrap; gap: .5rem; }
          .rdd-converge { border: 1px solid currentColor; border-radius: .25rem;
                          padding: 0 .25rem; opacity: .8; }

          /* the hierarchy: structure drawn with rails, algebra named on the
             node. A converging cell is drawn under every route that reaches
             it, subtree and all. */
          /* `.rdd li` (a bordered pill) is 0,1,1 and beats a bare `.rdd-hier-row`
             at 0,1,0 — so `border: 0` here silently never applied and every row
             rendered as a full-width box, which also swallowed the indent. Match
             the element too, so this wins on specificity rather than by luck. */
          .rdd-hier ol { list-style: none; margin: .25rem 0 0; padding: 0;
                         display: flex; flex-direction: column; gap: .0625rem; }
          .rdd-hier li.rdd-hier-row { display: flex; align-items: baseline;
                                      gap: .375rem; border: 0; border-radius: 0;
                                      padding: .1875rem 0 .1875rem
                                        calc(var(--indent) * 1.5rem); }
          .rdd-hier li.rdd-hier-row a { color: inherit; font-weight: 500; }
          /* the glyph sits in its own fixed column at the indent's left edge, so
             a child's NAME lands one full step right of its parent's */
          .rdd-hier .rdd-branch { opacity: .35; flex: none; width: 1.125rem;
                                  font-family: ui-monospace, monospace; }
          /* the operator, which IS the relationship — not decoration */
          .rdd-op { font-size: .6875rem; opacity: .75; font-family: ui-monospace, monospace;
                    border: 1px solid currentColor; border-radius: .25rem;
                    padding: 0 .3125rem; }
          .rdd-role { font-size: .6875rem; opacity: .55; font-style: italic; }
          .rdd-detail { font-size: .6875rem; opacity: .45;
                        font-family: ui-monospace, monospace; }
          /* a reference is dimmed: the edge is real, the subtree is elsewhere */
          .rdd-ref-row { opacity: .5; }
          .rdd-ref { font-style: italic; }

          /* leaves grouped by the crawl that feeds them: two halves of one
             crawl read as two independent sources when listed side by side */
          .rdd-group { margin-bottom: .75rem; }
          .rdd-group-label { font-size: .6875rem; text-transform: uppercase;
                             letter-spacing: .06em; opacity: .6; font-weight: 600;
                             margin: 0 0 .25rem; }
          .rdd-unscanned { opacity: .4; font-style: italic; }

          /* live vs polling — stated, not inferred */
          .rdd-live { margin-left: auto; font-size: .6875rem; letter-spacing: .06em;
                      text-transform: uppercase; display: inline-flex;
                      align-items: center; gap: .375rem; }
          .rdd-live::before { content: ""; width: .4375rem; height: .4375rem;
                              border-radius: 50%; background: currentColor; }
          .rdd-live-true { color: #1d7a4c; }
          .rdd-live-false { color: currentColor; opacity: .45; }

          /* the one thing the page DOES rather than displays */
          .rdd-scan { margin-top: .75rem; }
          .rdd-origin { margin: .25rem 0 .5rem; font-size: .8125rem; opacity: .7; }
          .rdd-actions { display: flex; gap: .5rem; }
          .rdd-actions button { font: inherit; font-size: .8125rem;
                                color: inherit; background: none; cursor: pointer;
                                border: 1px solid currentColor; border-radius: .25rem;
                                padding: .25rem .625rem; }
          .rdd-actions button:hover { opacity: .7; }
          .rdd-scan-result { margin: .5rem 0 0; font-size: .8125rem; opacity: .8; }
        </style>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
