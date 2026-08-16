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
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
