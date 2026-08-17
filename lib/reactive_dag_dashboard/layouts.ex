defmodule ReactiveDagDashboard.Layouts do
  @moduledoc """
  The dashboard's root layout.

  **The dashboard ships its own CSS.** The page is styled by
  `ReactiveDagDashboard.Components.styles/1` — about 200 lines of ordinary,
  `.rdd`-scoped CSS — so mounting it needs no stylesheet, no Tailwind
  configuration and no theme.

  It was built on daisyUI, so that it would inherit a host's theme and look
  like the rest of their admin. That never worked (a design that adapts to any
  theme commits to none) and it cost three configuration steps that each failed
  as a plausible-looking broken page: link a stylesheet (#18), point Tailwind at
  this dep so the classes compiled at all, and keep this layout or lose the
  component rules (#32).

  ## Getting the assets onto the page

  One setting, and it is about JavaScript:

      config :reactive_dag_dashboard,
        js_path: "/assets/app.js"

  Without it the LiveSocket never connects, so the page is static HTML and
  nothing on it is clickable — which from a browser looks like "the dashboard
  is broken" (u2i/reactive_dag_dashboard#21).

  `css_path:` is still read and still linked, but it is now OPTIONAL — a hook
  for a host that wants to layer a font or a colour override on top.

  Read at RENDER time rather than taken as an assign: `:root_layout` is a
  `{module, template}` tuple with no slot for assigns, so a root layout cannot
  be handed a value through the router. Config is the only channel that reaches
  here.

  A host mounting inside its own authenticated scope usually wants its own
  chrome instead — a nav bar, a user menu. Pass `:root_layout` to
  `reactive_dag_dashboard/2` and this layout is never used.

  ## What a `:root_layout` host still gets

  Everything. The whole stylesheet is rendered by the PAGE
  (`ReactiveDagDashboard.Components.styles/1`), not from this file, so replacing
  this layout cannot drop it.

  It could, once. Those rules lived in this module's `<style>` block, and a host
  supplying its own chrome silently lost every one of them: the page kept its
  daisyUI classes so it still looked styled, while the tree lost its structure
  and the graph drew nothing at all. The failure was invisible from here and
  undiagnosable from there (u2i/reactive_dag_dashboard#32).

  All a host takes on by overriding is loading JS that connects a LiveSocket,
  which their shell already does — so the missing-config warning below is
  correctly silent for them.
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
  @spec missing() :: [String.t()] | nil
  def missing do
    # `js_path` only. `css_path` was required when the page was built from
    # daisyUI class names it did not ship; it now ships its own CSS, so a host
    # that sets nothing gets a styled, working page. Warning about an optional
    # override would be crying wolf, and a warning nobody can act on is one
    # nobody reads.
    [{"js_path", js_path()}]
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
        <%!-- OPTIONAL now. The dashboard ships its own CSS, so this is only for
              a host that wants to layer something on top — a font, a colour
              override. It used to be required, and its absence rendered an
              unstyled page. --%>
        <link :if={css_path()} phx-track-static rel="stylesheet" href={css_path()} />
        <script :if={js_path()} defer phx-track-static type="text/javascript" src={js_path()}>
        </script>
        <%!-- No page styles here. They live with the COMPONENTS and are
              rendered by the page itself, so they survive a host supplying its
              own `root_layout:` — which the docs recommend and which used to
              drop every rule silently. See
              `ReactiveDagDashboard.Components.styles/1`. --%>
        <%!-- The document ground, so the page is not composited over whatever
              the browser defaults to. Matches the palette in
              `Components.styles/1`, including its dark variant — a light-only
              shell around a theme-aware page is a white band above a dark one. --%>
        <style>
          html, body { margin: 0; padding: 0; background: #ffffff; color: #1a2027 }
          .rdd-warn { margin: 16px; padding: 12px 16px; border: 1px solid #a86a12;
                      border-radius: 8px; background: #fdf1de; color: #5c4a26;
                      font: 13px/1.5 ui-sans-serif, system-ui }
          .rdd-warn p { margin: 0 }
          .rdd-warn p + p { margin-top: 4px }
          .rdd-warn pre { margin: 8px 0 0; font-size: 12px }
          @media (prefers-color-scheme: dark) {
            html, body { background: #0e1116; color: #cdd6df }
            .rdd-warn { border-color: #e0a93f; background: #2a2113; color: #f2c98a }
          }
        </style>
      </head>
      <body>
        <%!-- Styled by this layout's own `<head>`, not by the page's
              stylesheet: this warning fires when the page is missing what it
              needs to work, so it must not depend on anything that might be
              missing. --%>
        <div :if={missing()} role="alert" class="rdd-warn">
          <p style="font-weight:650">
            reactive_dag_dashboard is missing <%= Enum.join(missing(), " and ") %>.
          </p>
          <p>
            Without <code>js_path</code> the LiveSocket never connects, so nothing on this
            page is clickable.
          </p>
          <pre><code><%= config_snippet() %></code></pre>
        </div>

        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
