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
        </style>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
