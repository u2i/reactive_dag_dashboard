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

  `:root_layout` is overridable, so a host that wants its own chrome (a nav bar,
  a user menu) passes theirs and this is never used.
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
        <%= if assigns[:css_path] do %>
          <link phx-track-static rel="stylesheet" href={@css_path} />
        <% end %>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
