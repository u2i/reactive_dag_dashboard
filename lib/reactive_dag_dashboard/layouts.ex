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
        </style>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
