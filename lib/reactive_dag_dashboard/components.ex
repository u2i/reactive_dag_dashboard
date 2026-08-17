defmodule ReactiveDagDashboard.Components do
  @moduledoc """
  The dashboard's pieces.

  Split out of the LiveView because the page is now one view rather than three,
  and a single 600-line `render/1` is a page nobody can change safely.

  Every class here is this library's own, `rdd-` prefixed and defined in
  `styles/1`, which the page renders. The dashboard is self-contained: no
  framework, no host stylesheet, no build step. See `styles/1` for why that
  replaced the daisyUI it was built on.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias ReactiveDagDashboard.NodeDetail

  @doc """
  The dashboard's stylesheet, as a `<style>` block the PAGE renders.

  Everything the page needs, in about 200 lines of ordinary CSS. No framework,
  no build step, no host stylesheet — the dashboard is self-contained.

  ## Why it ships its own CSS

  This was built on daisyUI, on the reasoning that inheriting the host's theme
  would make the graph look like the rest of their admin rather than a bolted-on
  tool. That reasoning was wrong twice over.

  It did not work: cascade's dashboard shares no visual language with the rest
  of its `/admin`, because a design that adapts to any theme commits to none.
  And it made the page fragile in ways that had nothing to do with the graph — a
  host had to link a stylesheet (#18), point Tailwind at this dep so the classes
  were compiled at all, and keep this library's own root layout or lose the
  component rules (#32). Three configuration steps, each failing as a page that
  looked plausible and was subtly broken, none diagnosable from a browser.

  Owning the CSS removes all three. The trade is that the dashboard looks like
  itself wherever it is mounted, which is the honest description of what it was
  doing anyway.

  ## Why the page and not the layout

  A host with its own chrome passes `root_layout:` — which the docs recommend —
  and anything kept only in this library's layout is silently dropped for them.
  Rendered from `DagLive.render/1`, these rules arrive whatever wraps the page.

  A `<style>` in the body is not valid HTML by the letter of the spec, but every
  browser honours it and LiveView patches it like any other markup.

  ## Scoping

  Every rule is under `.rdd`, and every class is `rdd-` prefixed. A host's own
  stylesheet is loaded on the same page and must not be able to reach in here,
  nor these rules leak out into their nav.

  ## Colour

  The compliance portal's tokens, verbatim — `--u2i-bg` `#0e1116`, `--u2i-ink`
  `#e6edf3`, its border and panel greys, and its accent vocabulary. Same values,
  so the two surfaces are one look rather than two interpretations of one.

  **Dark only, deliberately.** This is an instrument panel, and committing to a
  ground is what makes it read as one. Three earlier passes kept a
  theme-neutral palette on the reasoning that it should adapt to any host —
  first opacity ramps of `currentColor`, then a light-first palette with a dark
  variant — and each time the result resembled nothing in particular. Adapting
  to every theme is how a design ends up with none.

  The portal's assurance hues map onto a DAG's four kinds by analogy: a SOURCE
  is *measured* (observed from outside the graph), a derived cell is *derived*,
  a JOIN *declares* a correspondence between its inputs.

  Kind colours the spine **and the name**. That is the portal's call and the
  load-bearing one: tinting only the spine leaves a column of identically grey
  names, which is why an earlier pass still read flat despite having the right
  structure.
  """
  def styles(assigns) do
    ~H"""
    <style>
      /* ── the u2i design-system tokens, VERBATIM ────────────────────────
         Lifted from the compliance portal's `:root` (assets/css/app.css) and
         its model tree, unchanged. Same values, same names, so the two
         surfaces are one look rather than two interpretations of one.

         Dark only, deliberately. This is an instrument panel — committing to
         a ground is what makes it read as one, and a palette that adapts to
         any host commits to none. Earlier versions of this file kept a light
         variant and a theme-neutral accent, and the result resembled nothing.

         `.rdd` rather than `:root`, because a host's page is around us. */
      .rdd {
        --bg: #0e1116;
        --panel: #161b22;
        --panel2: #1b212b;
        --border: #2a3441;
        --ink: #e6edf3;
        --dim: #9aa7b4;
        --faint: #6b7886;
        /* the portal's assurance vocabulary, mapped onto a DAG's four kinds:
           a SOURCE is measured (observed from outside the graph), a derived
           cell is derived, a JOIN declares a correspondence between inputs,
           and `gap` marks a node whose rows are not what they should be. */
        --measured: #5fd3bc;
        --derived: #7aa2f7;
        --attested: #f2c14e;
        --declared: #c98b5a;
        --gap: #e8736a;
        --accent: #7fe9c0;
        --indent: 26px;

        background: var(--bg);
        color: var(--ink);
        font: 13px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
        -webkit-font-smoothing: antialiased;
        padding: 22px 24px 40px;
        min-height: 100vh;
      }

      .rdd * { box-sizing: border-box }
      .rdd .hidden { display: none }

      /* ── page chrome ───────────────────────────────────────────────── */
      .rdd-head { display: flex; align-items: baseline; justify-content: space-between;
                  margin-bottom: 16px; max-width: 1080px }
      .rdd-head h1 { font-size: 17px; font-weight: 650; margin: 0; letter-spacing: -.01em;
                     font-family: ui-monospace, monospace; color: var(--ink) }

      .rdd-alert { background: var(--panel2); border: 1px solid var(--border);
                   border-left: 3px solid var(--accent); border-radius: 7px;
                   padding: 9px 13px; margin-bottom: 14px; font-size: 12.5px;
                   color: var(--dim); max-width: 1080px }

      .rdd-tabs { display: flex; gap: 3px; margin-bottom: 16px }
      .rdd-tab { font: inherit; font-size: 11px; font-weight: 700; letter-spacing: .07em;
                 text-transform: uppercase; color: var(--faint); background: none;
                 border: 1px solid transparent; padding: 4px 11px; cursor: pointer;
                 border-radius: 6px; font-family: ui-monospace, monospace }
      .rdd-tab:hover { color: var(--dim) }
      .rdd-tab.on { color: var(--bg); background: var(--accent); border-color: var(--accent) }

      /* ── the question, then its starting points ──────────────────────
         Direction is chosen FIRST and as a question in words, because that is
         what someone arrives with. "downstream" is the graph's word for it,
         not theirs. */
      .rdd-ask { display: flex; gap: 8px; margin-bottom: 14px; flex-wrap: wrap }
      .rdd-askbtn { display: flex; flex-direction: column; gap: 2px; text-align: left;
                    font: inherit; background: var(--panel); color: var(--dim);
                    border: 1px solid var(--border); border-radius: 9px;
                    padding: 9px 14px; cursor: pointer; min-width: 210px }
      .rdd-askbtn:hover { border-color: #3a4655 }
      .rdd-askbtn.on { border-color: var(--accent); background: var(--panel2) }
      .rdd-askq { font-size: 13px; font-weight: 650; color: var(--ink) }
      .rdd-askbtn.on .rdd-askq { color: var(--accent) }
      .rdd-askn { font-size: 9.5px; text-transform: uppercase; letter-spacing: .07em;
                  color: var(--faint); font-family: ui-monospace, monospace }

      .rdd-starts { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 16px;
                    max-width: 1080px }
      .rdd-start { font: inherit; font-family: ui-monospace, monospace; font-size: 11.5px;
                   color: var(--dim); background: var(--panel);
                   border: 1px solid var(--border); border-radius: 100px;
                   padding: 4px 12px; cursor: pointer }
      .rdd-start:hover { border-color: var(--measured); color: var(--measured) }
      .rdd-start.on { background: var(--measured); border-color: var(--measured);
                      color: var(--bg); font-weight: 700 }

      .rdd-prompt { font-size: 12.5px; color: var(--faint); margin: 0 }

      /* a row's own detail, opened in place — no page-level "selected" node */
      .rdd-drawer { margin: 0 0 6px var(--indent); padding-left: 16px;
                    border-left: 1px dashed #283341 }
      .rdd-drawer .rdd-card { margin-top: 0 }

      /* ── the picker ────────────────────────────────────────────────── */
      .rdd-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
                 margin-bottom: 16px; max-width: 1080px }
      .rdd-bar-lab { font-size: 9.5px; text-transform: uppercase; letter-spacing: .08em;
                     color: var(--faint); font-weight: 700;
                     font-family: ui-monospace, monospace }
      .rdd-bar-acts { display: flex; gap: 6px; margin-left: 4px }
      .rdd-routes { margin-left: auto; font-size: 11px; color: var(--faint);
                    font-variant-numeric: tabular-nums; font-family: ui-monospace, monospace }

      .rdd-picker { position: relative }
      .rdd-pick { font: inherit; font-family: ui-monospace, monospace; font-size: 12.5px;
                  font-weight: 700; color: var(--ink); background: var(--panel);
                  border: 1px solid var(--border); border-radius: 7px; padding: 5px 11px;
                  cursor: pointer; display: inline-flex; align-items: center; gap: 9px }
      .rdd-pick:hover { border-color: var(--accent); color: var(--accent) }
      .rdd-caret { color: var(--faint); font-size: 9px }

      .rdd-menu { position: absolute; top: calc(100% + 5px); left: 0; z-index: 30;
                  background: var(--panel); border: 1px solid var(--border);
                  border-radius: 9px; padding: 7px; min-width: 280px;
                  max-height: 400px; overflow-y: auto;
                  box-shadow: 0 12px 36px rgba(0,0,0,.5) }
      .rdd-menu-group + .rdd-menu-group { margin-top: 7px; padding-top: 7px;
                                          border-top: 1px solid var(--border) }
      .rdd-menu-head { font-size: 9px; text-transform: uppercase; letter-spacing: .08em;
                       color: var(--faint); font-weight: 700; padding: 3px 8px;
                       display: flex; gap: 7px; font-family: ui-monospace, monospace }
      .rdd-menu-item { display: block; width: 100%; text-align: left; font: inherit;
                       font-family: ui-monospace, monospace; font-size: 12px;
                       color: var(--dim); background: none; border: 0;
                       padding: 4px 8px; border-radius: 5px; cursor: pointer }
      .rdd-menu-item:hover { background: var(--panel2); color: var(--ink) }
      .rdd-menu-item.on { background: var(--panel2); color: var(--accent); font-weight: 700 }

      /* ── buttons ───────────────────────────────────────────────────── */
      .rdd-btn { font: inherit; font-family: ui-monospace, monospace; font-size: 10.5px;
                 font-weight: 700; letter-spacing: .04em; color: var(--dim);
                 background: var(--panel); border: 1px solid var(--border);
                 border-radius: 6px; padding: 4px 10px; cursor: pointer }
      .rdd-btn:hover { border-color: var(--accent); color: var(--accent) }
      .rdd-ghost { background: none }

      .rdd-seg { display: inline-flex; border: 1px solid var(--border); border-radius: 7px;
                 overflow: hidden }
      .rdd-segbtn { font: inherit; font-family: ui-monospace, monospace; font-size: 10.5px;
                    font-weight: 700; letter-spacing: .04em; color: var(--faint);
                    background: var(--panel); border: 0; padding: 5px 11px; cursor: pointer }
      .rdd-segbtn + .rdd-segbtn { border-left: 1px solid var(--border) }
      .rdd-segbtn:hover { color: var(--ink) }
      .rdd-segbtn.on { background: var(--accent); color: var(--bg) }

      /* ── badges: a tint of the hue, with the hue as the text ──────────
         The portal's `color-mix(in srgb, <hue> 22%, transparent)` fill under
         text of the SAME hue. A flat pastel background with darker text —
         which is what this had — reads as a different design language. */
      .rdd-badge { font-size: 9px; font-weight: 700; padding: 2px 7px; border-radius: 100px;
                   white-space: nowrap; font-family: ui-monospace, monospace;
                   letter-spacing: .03em }
      .rdd-b-ok { background: color-mix(in srgb, var(--measured) 22%, transparent);
                  color: var(--measured) }
      .rdd-b-warn { background: color-mix(in srgb, var(--gap) 20%, transparent);
                    color: #e8918a }
      .rdd-b-mute { background: #222a36; color: var(--faint) }

      /* ── the dead end ──────────────────────────────────────────────── */
      .rdd-empty { border: 1px dashed var(--border); border-radius: 9px; padding: 22px;
                   background: var(--panel); text-align: center; color: var(--dim);
                   max-width: 1080px }
      .rdd-empty p { margin: 0 0 12px }
      .rdd-empty strong { color: var(--ink); font-weight: 700;
                          font-family: ui-monospace, monospace }

      .rdd-cap { font-size: 11px; color: var(--faint); margin: 8px 0 0;
                 font-family: ui-monospace, monospace }
      .rdd-cap code { color: var(--dim) }

      /* ── the expression tree — the portal's model tree ────────────────
         `.row` is a bordered card; `.children` nests INSIDE the node with the
         indent and a dashed rail. Both verbatim from
         lib/u2i_portal_web/components/model_tree.ex. */
      .rdd-tree { --indent: 26px; max-width: 1080px }
      .rdd-node { margin: 6px 0 }

      .rdd-row { display: flex; align-items: flex-start; gap: 10px;
                 border: 1px solid var(--border); border-radius: 9px; padding: 9px 12px;
                 background: var(--panel); position: relative; cursor: pointer }
      .rdd-row:hover { border-color: #3a4655 }
      .rdd-on > .rdd-row, .rdd-row.rdd-on { border-color: var(--accent);
                                            background: var(--panel2) }

      /* a set, not a single row — the portal's four-layer stacked card */
      .rdd-many > .rdd-row {
        box-shadow: 3px 3px 0 0 var(--panel), 4px 4px 0 0 var(--border),
                    6px 6px 0 0 var(--panel), 7px 7px 0 0 var(--border);
      }
      .rdd-many { margin-bottom: 12px }

      /* the spine, bled to the card edges by negative margin */
      .rdd-lead { width: 4px; align-self: stretch; flex: 0 0 4px; margin: -9px 0 -9px -12px;
                  border-radius: 9px 0 0 9px; background: var(--border) }

      /* KIND on the spine AND the name — the portal tints both, which is what
         makes a column of names scannable as kinds before they are read. */
      .rdd-source > .rdd-row > .rdd-lead { background: var(--measured) }
      .rdd-source > .rdd-row .rdd-name button { color: #8fe0d0 }
      .rdd-derive > .rdd-row > .rdd-lead { background: #4a5a6a }
      .rdd-derive > .rdd-row .rdd-name button { color: #9fb0c0 }
      .rdd-join   > .rdd-row > .rdd-lead { background: var(--declared) }
      .rdd-join   > .rdd-row .rdd-name button { color: #e0b884 }
      .rdd-plain  > .rdd-row > .rdd-lead { background: var(--border) }
      .rdd-plain  > .rdd-row .rdd-name button { color: #cdd6df }

      .rdd-chev { flex: 0 0 14px; width: 14px; text-align: center; color: var(--faint);
                  font-size: 10px; align-self: flex-start; margin-top: 1px;
                  user-select: none; transition: transform .12s }
      .rdd-chev-none { visibility: hidden }
      .rotate-90 { transform: rotate(90deg) }

      .rdd-body { flex: 1; min-width: 0 }

      .rdd-kind { font-size: 9.5px; text-transform: uppercase; letter-spacing: .07em;
                  color: var(--faint); font-weight: 700; display: flex; flex-wrap: wrap;
                  align-items: center; gap: 6px }
      .rdd-op { font-family: ui-monospace, monospace; font-weight: 700; color: #9fb0c0;
                text-transform: none; letter-spacing: 0; font-size: 10.5px }
      /* the operation, as a link to what implements it */
      .rdd-op-link { text-decoration: none; border-bottom: 1px dotted transparent }
      .rdd-op-link:hover { color: var(--derived); border-bottom-color: var(--derived) }

      /* a scanner's cadence, next to its name */
      .rdd-cadence { font-family: ui-monospace, monospace; font-size: 9.5px;
                     color: var(--faint); text-transform: none; letter-spacing: 0 }

      /* scan controls, inline on the ~6 rows that declare a scanner */
      .rdd-scan { display: inline-flex; gap: 4px; align-items: center; margin-left: 2px }
      .rdd-mini { font: inherit; font-family: ui-monospace, monospace; font-size: 9px;
                  font-weight: 700; letter-spacing: .04em; text-transform: uppercase;
                  color: var(--measured); background: color-mix(in srgb, var(--measured) 14%, transparent);
                  border: 1px solid color-mix(in srgb, var(--measured) 30%, transparent);
                  border-radius: 100px; padding: 1px 8px; cursor: pointer }
      .rdd-mini:hover { background: var(--measured); color: var(--bg);
                        border-color: var(--measured) }
      /* a slice is a narrowing of the same act, so it reads as a variant of
         the button beside it rather than a different control */
      .rdd-mini-slice { color: var(--attested); text-transform: none;
                        background: color-mix(in srgb, var(--attested) 14%, transparent);
                        border-color: color-mix(in srgb, var(--attested) 30%, transparent) }
      .rdd-mini-slice:hover { background: var(--attested); color: var(--bg);
                              border-color: var(--attested) }

      .rdd-ccount { font-family: ui-monospace, monospace; font-size: 9px; background: #222a36;
                    color: var(--dim); padding: 0 6px; border-radius: 100px }
      .rdd-grain { font-family: ui-monospace, monospace; font-size: 9px; font-weight: 700;
                   padding: 1px 6px; border-radius: 100px; text-transform: none }
      .rdd-grain-many { background: color-mix(in srgb, #bb9af7 18%, transparent);
                        color: #cdb6fb }
      .rdd-grain-one { background: #222a36; color: var(--faint) }

      .rdd-name { font-size: 13.5px; font-weight: 600; margin-top: 1px }
      .rdd-name button { font: inherit; background: none; border: 0; padding: 0;
                         cursor: pointer; text-align: left; color: #cdd6df }
      .rdd-name button:hover { text-decoration: underline }

      .rdd-count { font-size: 11px; color: var(--faint); font-variant-numeric: tabular-nums;
                   font-family: ui-monospace, monospace; margin-left: auto;
                   padding-left: 12px; flex-shrink: 0; margin-top: 2px }

      .rdd-children { margin-left: var(--indent); padding-left: 16px;
                      border-left: 1px dashed #283341 }

      /* ── the node panel ────────────────────────────────────────────── */
      .rdd-card { border: 1px solid var(--border); border-radius: 9px; background: var(--panel);
                  padding: 15px 17px; margin-top: 20px; max-width: 1080px }
      .rdd-card h2 { font-size: 15px; font-weight: 700; margin: 0;
                     font-family: ui-monospace, monospace; color: var(--ink) }
      .rdd-card-head { display: flex; align-items: baseline; gap: 9px; flex-wrap: wrap;
                       margin-bottom: 9px }
      .rdd-lede { font-size: 12.5px; color: var(--dim); margin: 0 0 11px; max-width: 68ch }
      .rdd-facts { display: flex; gap: 18px; flex-wrap: wrap; font-size: 11.5px;
                   color: var(--dim); margin-bottom: 11px }
      .rdd-facts .k { color: var(--faint); text-transform: uppercase; font-size: 9px;
                      letter-spacing: .07em; font-weight: 700; margin-right: 5px;
                      font-family: ui-monospace, monospace }
      .rdd-sec { border-top: 1px solid var(--border); padding-top: 11px; margin-top: 11px }
      .rdd-sec-head { font-size: 9px; text-transform: uppercase; letter-spacing: .08em;
                      color: var(--faint); font-weight: 700; margin-bottom: 7px;
                      font-family: ui-monospace, monospace }
      .rdd-row-acts { display: flex; gap: 6px; align-items: center; flex-wrap: wrap }
      .rdd-link { color: var(--derived); text-decoration: none; font-size: 11px;
                  font-family: ui-monospace, monospace }
      .rdd-link:hover { text-decoration: underline }
      .rdd-mono { font-family: ui-monospace, monospace; font-size: 11px; color: var(--dim) }

      .rdd-tbl { width: 100%; border-collapse: collapse; font-size: 11.5px }
      .rdd-tbl td { padding: 4px 10px 4px 0; color: var(--dim);
                    font-variant-numeric: tabular-nums; font-family: ui-monospace, monospace }
      .rdd-tbl tr + tr td { border-top: 1px solid var(--border) }

      /* ── the SVG graph ─────────────────────────────────────────────── */
      .rdd-graph { color: var(--ink); display: block }
      .rdd-gwrap { border: 1px solid var(--border); border-radius: 9px; background: var(--panel);
                   padding: 10px; overflow-x: auto; max-width: 1080px }

      .rdd-gbox { fill: var(--panel2); stroke: var(--border); stroke-width: 1.5;
                  cursor: pointer }
      .rdd-gbox:hover { stroke: #3a4655 }
      .rdd-gbox-on { stroke: var(--accent); stroke-width: 2 }
      .rdd-gstack { fill: none; stroke: var(--border); opacity: .6 }

      .rdd-gop { fill: var(--bg); stroke: #4a5a6a; stroke-width: 1.5; cursor: pointer }
      .rdd-gop:hover { stroke: var(--dim) }
      .rdd-gop-on { stroke: var(--accent); stroke-width: 2 }

      .rdd-edge { stroke: #2a3441; stroke-width: 1.4; fill: none }
      .rdd-edge-hot { stroke: var(--accent); stroke-width: 2 }

      .rdd-gtext { font-size: 11.5px; font-weight: 600; fill: #cdd6df;
                   font-family: ui-monospace, monospace }
      .rdd-gsub { font-size: 9px; fill: var(--faint); font-family: ui-monospace, monospace;
                  text-transform: uppercase; letter-spacing: .06em }
      .rdd-goplabel { font-size: 9.5px; fill: #9fb0c0; font-family: ui-monospace, monospace;
                      font-weight: 700 }
    </style>
    """
  end


  attr(:node, :map, required: true)
  attr(:status, :map, required: true)
  attr(:details, :map, required: true)

  @doc """
  The hierarchy: what a change reaches, as an EXPRESSION.

  Each node renders as a function application —
  `reduce( folded: expenses ) by :category` — so an edge says what the input IS
  to the node reading it. A join's left and right are not interchangeable, a
  union's inputs are alternatives, and a bare arrow says neither.

  ## Nesting is structure, not arithmetic

  Two earlier shapes lost this. Flat `<li>`s pushed right by `margin-left:
  depth * 26px` render the same information and read worse: at four levels the
  eye cannot tell which ancestor a row belongs to, and nothing bounds a
  subtree. Adding card borders helped the row and not the tree — the cards were
  still siblings pretending to be nested.

  So this RECURSES. A node's children live in a wrapper inside the node, and
  that wrapper carries the indent and a dashed rail down its edge. Containment
  is real, so a subtree is visibly a region of the page and the rail is what
  makes a deep one scannable. The compliance portal's model tree does exactly
  this, and its reasoning holds here.

  ## Two lines, not one

  A single baseline row puts the id, its badges, the algebra and the key count
  in one horizontal run at one weight, and nothing wins. The portal splits them:
  a small uppercase KIND line carrying the operation and its badges, then the
  NAME beneath at reading weight. Scanning down a column of names is what the
  eye is good at; scanning a run of mixed-weight fragments is not.

  Collapsed below depth 1 by default, with a child count on every collapsible
  node: a 7-deep graph is unreadable fully expanded, and a collapsed node with
  no count looks like a leaf.

  Toggling is `Phoenix.LiveView.JS` — a class flip in the browser, no server
  round-trip, so opening a branch costs nothing. The toggle targets the
  wrapper by id rather than a prefix selector over every descendant, which is
  what nesting buys.
  """
  def hierarchy(assigns) do
    ~H"""
    <div class="rdd-tree">
      <.tree_node node={@node} status={@status} details={@details} />
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:status, :map, required: true)
  attr(:details, :map, required: true)

  defp tree_node(assigns) do
    ~H"""
    <div class={[
      "rdd-node",
      kind_class(@node),
      @node.routes > 1 && "rdd-many",
      @node.closed? && "rdd-closed"
    ]}>
      <div class="rdd-row">
        <span class="rdd-lead"></span>

        <span
          :if={@node.children > 0}
          id={"chev-#{@node.path}"}
          class={["rdd-chev", not @node.closed? && "rotate-90"]}
          phx-click={toggle_kids(@node)}
        >
          ▸
        </span>
        <span :if={@node.children == 0} class="rdd-chev rdd-chev-none"></span>

        <div class="rdd-body">
          <div class="rdd-kind">
            <%!-- The operation IS the link. The kind line already prints what
                  this node does — `REDUCE( … )`, `AgendaItems( … )` — and the
                  module that implements it is what you want when you read
                  that. A separate icon would be a third element on a line that
                  already carries an operator and a count; the link used to sit
                  inside the drawer, where nobody found it. --%>
            <a
              :if={@details[@node.id] && link_url(@details[@node.id])}
              href={link_url(@details[@node.id])}
              target="_blank"
              rel="noopener"
              class="rdd-op rdd-op-link"
              title={link_title(@details[@node.id])}
            >
              <%= op_label(@node, @details[@node.id]) %> ↗
            </a>
            <span
              :if={!(@details[@node.id] && link_url(@details[@node.id]))}
              class="rdd-op"
            >
              <%= op_label(@node, @details[@node.id]) %>
            </span>

            <%!-- A scanner's CADENCE, beside its name: "every 0 12 * * *" is
                  what tells you whether a stale count is expected. --%>
            <span :if={cadence(@details[@node.id])} class="rdd-cadence">
              · <%= cadence(@details[@node.id]) %>
            </span>

            <span :if={@node.children > 1} class="rdd-ccount"><%= @node.children %></span>

            <span :if={@node.routes > 1 and not @node.repeat?} class="rdd-grain rdd-grain-many">
              × <%= @node.routes %> routes
            </span>

            <span :if={@node.repeat?} class="rdd-grain rdd-grain-one" title="expanded under its other input">
              also here
            </span>

            <span
              :for={{status, n} <- statuses(@status[@node.id])}
              class={["rdd-badge", status_badge(status)]}
            >
              <%= status %> <%= n %>
            </span>

            <%!-- Scan controls INLINE, and only where they mean something. Six
                  of this graph's 33 cells declare a scanner, so the cost is
                  six rows carrying three small buttons and 27 carrying none —
                  against a drawer you had to open to find the thing you came
                  to press. --%>
            <span :if={scanner(@details[@node.id])} class="rdd-scan">
              <button
                class="rdd-mini"
                phx-click="scan"
                phx-value-cell={@node.id}
                phx-value-mode="default"
                title="poll with the declared args"
              >
                scan
              </button>

              <button
                :if={scanner(@details[@node.id]).args != []}
                class="rdd-mini"
                phx-click="scan"
                phx-value-cell={@node.id}
                phx-value-mode="full"
                title="ignores the declared bound"
              >
                full
              </button>

              <button
                :for={{slice, value} <- slice_values(@details[@node.id])}
                class="rdd-mini rdd-mini-slice"
                phx-click="scan"
                phx-value-cell={@node.id}
                phx-value-mode="default"
                phx-value-column={slice.column}
                phx-value-value={value}
                title={"poll for #{slice.label} #{value} only"}
              >
                <%= value %>
              </button>
            </span>
          </div>

          <%!-- The name opens THIS row's detail, in place. It used to select
                the node, which re-rendered one panel at the foot of the page
                for whichever row you last clicked — so the answer to "what is
                this" appeared a scroll away from the thing you asked about,
                and asking about a second row replaced the first. --%>
          <div class="rdd-name">
            <button type="button" phx-click={toggle_detail(@node)}>
              <%= @node.id %>
            </button>
          </div>
        </div>

        <span class="rdd-count" title={count_title(@status[@node.id])}>
          <%= key_count(@status[@node.id]) %>
        </span>
      </div>

      <div id={"det-#{@node.path}"} class="rdd-drawer hidden">
        <.detail detail={@details[@node.id]} />
      </div>

      <div
        :if={@node.children > 0}
        id={"kids-#{@node.path}"}
        class={["rdd-children", @node.closed? && "hidden"]}
      >
        <.tree_node :for={kid <- @node.kids} node={kid} status={@status} details={@details} />
      </div>
    </div>
    """
  end

  # What this node DOES, as the kind line's headline.
  #
  # A scanner says so and names itself — `poll · Village AgendaCenter` — rather
  # than the generic "leaf" every source used to share. The teal spine already
  # says "nothing feeds this", which is not the same as "something crawls it",
  # and it could not say WHAT crawls it. `origin/0` is the scanner's own name
  # for itself and is usually the most recognisable string on the row.
  defp op_label(node, detail) do
    cond do
      s = scanner(detail) -> "poll · #{origin_label(s) || short(s.source)}"
      app = application(node) -> app
      true -> "leaf"
    end
  end

  defp origin_label(%{origin: origin}) when is_map(origin), do: origin[:label]
  defp origin_label(_), do: nil

  defp scanner(%{scanner: %{} = s}), do: s
  defp scanner(_), do: nil

  defp cadence(detail) do
    case scanner(detail) do
      %{every: every} when is_binary(every) -> "every #{every}"
      _ -> nil
    end
  end

  defp link_url(%{implementation: %{url: url}}) when is_binary(url), do: url
  defp link_url(_), do: nil

  defp link_title(%{implementation: %{module: mod}}), do: "#{inspect(mod)} ↗"
  defp link_title(_), do: nil

  # `{slice, value}` pairs, flattened — a slice with no enumerable values
  # renders nothing rather than a label with no buttons after it.
  defp slice_values(detail) do
    for slice <- Map.get(detail || %{}, :slices, []),
        value <- slice.values || [],
        do: {slice, value}
  end

  # Open this row's detail. Per PATH, not per cell: a converging node is drawn
  # under every route that reaches it, and opening one occurrence must not open
  # the others.
  defp toggle_detail(node), do: JS.toggle(to: "#det-#{node.path}")

  # The spine's colour says what KIND of node this is before the label is read:
  # where data ENTERS the graph, where it is COMBINED, and where it is merely
  # carried. Three kinds, because the library has three — inventing a colour per
  # operator would imply a taxonomy that does not exist.
  defp kind_class(%{cell: nil}), do: "rdd-plain"

  defp kind_class(%{cell: cell}) do
    cond do
      cell.inputs == [] -> "rdd-source"
      length(cell.inputs) > 1 -> "rdd-join"
      true -> "rdd-derive"
    end
  end

  # One wrapper, addressed by id. The flat version had to match a PREFIX over
  # every descendant row; nesting means the children are already one element.
  defp toggle_kids(node) do
    JS.toggle(to: "#kids-#{node.path}")
    |> JS.toggle_class("rotate-90", to: "#chev-#{node.path}")
  end

  defp application(row), do: ReactiveDagDashboard.Algebra.application(row.cell)

  attr(:detail, :map, default: nil)

  @doc """
  One node, in full: what it does, where its code is, what it holds, and what it
  recently did.

  The last is the part a graph picture cannot show. A node that looks
  structurally fine and has not recomputed in a week is the interesting case,
  and nothing about its shape reveals that.
  """
  def detail(assigns) do
    ~H"""
    <div :if={@detail} class="rdd-card">
      <div class="rdd-card-head">
        <h2><%= @detail.id %></h2>

        <span :if={@detail.algebra.label} class="rdd-badge rdd-b-mute">
          <%= @detail.algebra.label %>
        </span>

        <a
          :if={@detail.implementation && @detail.implementation.url}
          href={@detail.implementation.url}
          target="_blank"
          rel="noopener"
          class="rdd-link"
        >
          <%= short(@detail.implementation.module) %> ↗
        </a>
      </div>

      <p :if={NodeDetail.headline(@detail)} class="rdd-lede">
        <%= NodeDetail.headline(@detail) %>
      </p>

      <div class="rdd-facts">
        <div :if={@detail.inputs != []}>
          <span class="k">reads</span><%= Enum.join(@detail.inputs, ", ") %>
        </div>
        <div :if={@detail.outputs != []}>
          <span class="k">feeds</span><%= Enum.join(@detail.outputs, ", ") %>
        </div>
        <div :if={@detail.algebra.detail} class="rdd-mono">
          <%= @detail.algebra.detail %>
        </div>
      </div>

      <div :if={@detail.steps != []} class="rdd-sec">
        <div class="rdd-sec-head">recent recomputes</div>
        <table class="rdd-tbl">
          <tbody>
            <tr :for={step <- @detail.steps}>
              <td><%= ms(step.duration_us) %></td>
              <td><%= length(step.changed) %> changed</td>
              <td>
                <span :if={step.triggered_by}>after <%= step.triggered_by %></span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@detail.steps == []} class="rdd-sec">
        <div class="rdd-sec-head">recent recomputes</div>
        <p class="rdd-lede" style="margin:0">no recorded recomputes</p>
      </div>

      <div :if={@detail.scanner} class="rdd-sec">
        <div class="rdd-sec-head">
          scanner
          <span :if={@detail.scanner.origin}>· <%= @detail.scanner.origin[:label] %></span>
        </div>

        <div class="rdd-row-acts">
          <button class="rdd-btn" phx-click="scan" phx-value-cell={@detail.id} phx-value-mode="default">
            <%= if @detail.scanner.args != [], do: "quick scan", else: "run scan" %>
          </button>

          <button
            :if={@detail.scanner.args != []}
            class="rdd-btn"
            phx-click="scan"
            phx-value-cell={@detail.id}
            phx-value-mode="full"
            title="ignores the declared bound"
          >
            full scan
          </button>

          <code :if={@detail.scanner.every} class="rdd-mono">
            every <%= @detail.scanner.every %>
          </code>
        </div>

        <div :for={slice <- @detail.slices} class="rdd-row-acts" style="margin-top:8px">
          <span class="rdd-sec-head" style="margin:0">just <%= slice.label %></span>

          <button
            :for={value <- slice.values || []}
            class="rdd-btn rdd-ghost"
            phx-click="scan"
            phx-value-cell={@detail.id}
            phx-value-mode="default"
            phx-value-column={slice.column}
            phx-value-value={value}
            title={"poll the source for #{slice.label} #{value} only"}
          >
            <%= value %>
          </button>
        </div>
      </div>

      <div :if={@detail.slices != []} class="rdd-sec">
        <div class="rdd-sec-head">reprocess</div>

        <div :for={slice <- @detail.slices} class="rdd-row-acts" style="margin-bottom:6px">
          <span class="rdd-sec-head" style="margin:0"><%= slice.label %></span>

          <button
            :for={value <- slice.values || []}
            class="rdd-btn rdd-ghost"
            phx-click="reprocess"
            phx-value-cell={@detail.id}
            phx-value-column={slice.column}
            phx-value-value={value}
          >
            <%= value %>
          </button>
        </div>

        <button
          class="rdd-btn"
          phx-click="reprocess"
          phx-value-cell={@detail.id}
          title="and everything below it"
        >
          whole cell
        </button>
      </div>
    </div>
    """
  end

  attr(:levels, :list, required: true)
  attr(:status, :map, required: true)
  attr(:selected, :string, default: nil)
  attr(:plan, :map, required: true)

  @doc """
  The graph as a drawn diagram: values as boxes, OPERATIONS as diamonds between
  them.

  The tree answers *"what does a change here reach"* and repeats a cell once per
  route to do it. This answers *"what is the shape of this"* — two routes
  converging are two lines meeting, drawn once. Same expression, two readings,
  and neither is a better version of the other.

  ## Why it is scoped to the selected node

  The first version drew the WHOLE plan: every cell in the graph, every edge,
  on one canvas. At seven nodes that is a diagram; at twenty-seven it is a
  black tangle where labels overlap their neighbours and no path is traceable,
  which is what shipped and what made this tab look like a mistake.

  The tree never had that problem, because it is scoped — one panel per source,
  and the panel only contains what that source reaches. This takes the same
  scope from the same place: `Tree.levels/2` over the selected node's reachable
  set. So the two tabs show the same subgraph, from either end, and the diagram
  stays the size a diagram can be.

  ## Why a diamond between the boxes

  A box-per-cell diagram draws `agenda_docs → agenda_items` and leaves the
  operation implicit in the arrow. But the operation is the interesting part:
  four inputs meeting at a `MeetingJoin` is a join, and drawing it as four
  arrows into a box says only that they arrive.

  So a derived cell renders as its inputs → a diamond → its box. The diamond
  carries the operator name; every operation is the same shape, because the
  flavour is a label and inventing a shape per operator would imply a taxonomy
  the library does not have. That is the older compliance portal's call and its
  reasoning holds: *one derive move*.

  Columns are the band a cell falls in — its distance from the origin, which is
  its greatest distance, so a cell never renders left of something it depends
  on. That IS the layered assignment; there is no layout algorithm here.
  """
  def graph(assigns) do
    assigns = assign(assigns, :g, geometry(assigns.levels, assigns.plan))

    ~H"""
    <div class="rdd-gwrap">
      <svg viewBox={"0 0 #{@g.width} #{@g.height}"} width={@g.width} height={@g.height} class="rdd-graph">
        <path
          :for={seg <- @g.segments}
          d={seg.d}
          class={["rdd-edge", seg.hot? && "rdd-edge-hot"]}
        />

        <g :for={op <- @g.ops}>
          <rect
            x={op.cx - op.r}
            y={op.cy - op.r}
            width={op.r * 2}
            height={op.r * 2}
            transform={"rotate(45 #{op.cx} #{op.cy})"}
            class={["rdd-gop", op.id == @selected && "rdd-gop-on"]}
            phx-click="select"
            phx-value-cell={op.id}
          />
          <text x={op.cx} y={op.cy - op.r - 4} text-anchor="middle" class="rdd-goplabel">
            <%= op.label %>
          </text>
        </g>

        <g :for={box <- @g.boxes}>
          <rect
            :if={box.many?}
            x={box.x + 3}
            y={box.y + 3}
            width={box.w}
            height={box.h}
            rx="5"
            class="rdd-gstack"
          />
          <rect
            x={box.x}
            y={box.y}
            width={box.w}
            height={box.h}
            rx="5"
            class={["rdd-gbox", box.id == @selected && "rdd-gbox-on"]}
            phx-click="select"
            phx-value-cell={box.id}
          />
          <text x={box.x + 9} y={box.y + 19} class="rdd-gtext"><%= box.id %></text>
          <text x={box.x + 9} y={box.y + 32} class="rdd-gsub"><%= box.sub %></text>
        </g>
      </svg>
    </div>
    """
  end

  @col_w 150
  @col_gap 96
  @row_h 42
  @row_gap 22
  @op_r 9
  @pad 16

  # Boxes on the distance bands; a diamond in the GAP before each derived cell,
  # where its inputs converge. Edges then run input → diamond → box, so the
  # operation sits on the path rather than being implied by it.
  #
  # Each column is centred vertically against the tallest, so a band of one node
  # sits beside the middle of a band of six rather than at its top — which is
  # what made the edges cross far more than the graph actually does.
  defp geometry(levels, plan) do
    tall = tallest(levels)

    boxes =
      for {{_distance, cells}, col} <- Enum.with_index(levels),
          {cell, row} <- Enum.with_index(cells),
          into: %{} do
        offset = (tall - length(cells)) * (@row_h + @row_gap) / 2

        {cell.id,
         %{
           id: cell.id,
           x: @pad + col * (@col_w + @col_gap),
           y: @pad + offset + row * (@row_h + @row_gap),
           w: @col_w,
           h: @row_h,
           col: col,
           routes: Map.get(cell, :routes, 1),
           via: Map.get(cell, :via, [])
         }}
      end

    ops = for {id, box} <- boxes, box.col > 0, op = op_for(plan, id, box), do: op

    %{
      boxes: Enum.map(boxes, fn {_id, b} -> decorate(b, plan) end),
      ops: ops,
      segments: segments(plan, boxes, ops),
      width: @pad * 2 + length(levels) * (@col_w + @col_gap),
      height: @pad * 2 + tall * (@row_h + @row_gap)
    }
  end

  defp tallest(levels),
    do: levels |> Enum.map(fn {_d, c} -> length(c) end) |> Enum.max(fn -> 1 end)

  # `routes` comes from the scoped tree — how many paths reach this cell WITHIN
  # this subgraph — rather than the plan's global parent count, which would mark
  # a node "many" for arrivals the picture does not contain.
  defp decorate(box, plan) do
    Map.merge(box, %{
      many?: box.routes > 1,
      sub: op_name(plan.cells[box.id]) || ""
    })
  end

  # The diamond sits midway between the deepest input's column and this one, so
  # the edges into it are short and the fan-in is visible as a point.
  defp op_for(plan, id, box) do
    case plan.cells[id] do
      nil ->
        nil

      cell ->
        %{
          id: id,
          cx: box.x - @col_gap / 2,
          cy: box.y + @row_h / 2,
          r: @op_r,
          label: op_name(cell) || "·"
        }
    end
  end

  defp op_name(nil), do: nil

  defp op_name(cell) do
    case ReactiveDagDashboard.Algebra.label(cell) do
      nil -> nil
      label -> label |> String.split(" ") |> hd()
    end
  end

  # input box → its diamond, then diamond → the box it produces.
  #
  # `b = boxes[from]` is a filter as much as a binding: an input OUTSIDE this
  # subgraph has no box, the comprehension drops it, and no edge is drawn to a
  # node that is not on the canvas. That is the honest rendering of a scoped
  # view — the diamond's fan-in shows the inputs this picture contains.
  defp segments(_plan, boxes, ops) do
    by_id = Map.new(ops, &{&1.id, &1})

    into_ops =
      for {to, op} <- by_id,
          from <- inputs_within(boxes, to),
          b = boxes[from],
          do: %{d: curve(b.x + b.w, b.y + @row_h / 2, op.cx - @op_r, op.cy), hot?: false}

    out_of_ops =
      for {to, op} <- by_id, b = boxes[to] do
        %{d: curve(op.cx + @op_r, op.cy, b.x, b.y + @row_h / 2), hot?: false}
      end

    into_ops ++ out_of_ops
  end

  # The cells this one is REACHED FROM inside this subgraph — `via` from the
  # scoped tree, which is direction-agnostic by construction: downstream it is
  # the parent a change arrived through, upstream it is the input. Either way it
  # is the neighbour one band to the left, which is where the edge belongs.
  #
  # Deriving this from `plan.cells[to].inputs` instead would be wrong in both
  # directions at once: it names inputs that are not on the canvas, and in the
  # upstream view those inputs sit to the RIGHT, so the edge doubles back.
  defp inputs_within(boxes, to) do
    case boxes[to] do
      nil -> []
      %{via: via} -> Enum.filter(via, &Map.has_key?(boxes, &1))
    end
  end

  # horizontal-tangent cubic: leaves rightward, arrives leftward, so flow reads
  # without arrowheads
  defp curve(x1, y1, x2, y2) do
    mx = (x1 + x2) / 2
    "M#{x1},#{y1} C#{mx},#{y1} #{mx},#{y2} #{x2},#{y2}"
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp short(mod) when is_atom(mod), do: mod |> Module.split() |> List.last()
  defp short(other), do: inspect(other)

  defp ms(us) when is_integer(us), do: "#{Float.round(us / 1000, 1)}ms"
  defp ms(_), do: "—"

  # A nil status is "this node has no :status column" — a rollup, not a verdict —
  # so only real statuses get a chip. Showing `nil` would be noise on most nodes.
  defp statuses(nil), do: []

  defp statuses(%{statuses: statuses}) do
    statuses
    |> Enum.reject(fn {k, _} -> is_nil(k) end)
    |> Enum.sort()
  end

  # `present` is the good case and needs no colour; anything else is the host's
  # own vocabulary, and a warning tint is the honest default for "not present".
  #
  # Only two, deliberately. The library does not know a host's status words —
  # `tombstoned`, `failing` and `thin` are all just "not present" here — so
  # inventing a colour per value would be inventing a meaning per value.
  defp status_badge("present"), do: "rdd-b-ok"
  defp status_badge(_other), do: "rdd-b-warn"

  # three states, one of which is a problem. See NodeDetail / Insights `rows:`.
  # `changed` alone cannot separate "nothing needed redoing" from "the request
  # never reached the rows", so the count carries WHY it is what it is.
  defp count_title(nil), do: "no status for this cell"
  defp count_title(%{rows: :unreadable}), do: "could not read this node's rows"

  defp count_title(%{rows: :elsewhere}),
    do: "this node keeps its rows elsewhere — nothing to count here"

  defp count_title(%{key_count: 0}), do: "no rows"
  defp count_title(%{key_count: n}), do: "#{n} keys"

  defp key_count(nil), do: "?"
  defp key_count(%{rows: :unreadable}), do: "?"
  defp key_count(%{rows: :elsewhere}), do: "—"
  defp key_count(%{key_count: n}), do: n
end
