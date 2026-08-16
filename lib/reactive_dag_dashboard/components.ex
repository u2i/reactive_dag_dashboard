defmodule ReactiveDagDashboard.Components do
  @moduledoc """
  The dashboard's pieces, in daisyUI.

  Split out of the LiveView because the page is now one view rather than three,
  and a single 600-line `render/1` is a page nobody can change safely.

  Every class here is daisyUI's — the host supplies the stylesheet, so the
  dashboard inherits their theme rather than shipping a look that clashes with
  the admin around it.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias ReactiveDagDashboard.NodeDetail

  attr(:sources, :list, required: true)
  attr(:status, :map, required: true)
  attr(:selected, :string, default: nil)

  @doc """
  The sources: what feeds this graph, and when it last ran.

  A TABLE rather than a heading-per-source with one pill under it. Seven
  sources took ~800px of mostly whitespace that way, and the shape hid the
  thing worth comparing — cadence and freshness side by side, so a source that
  has not run when it should have stands out.
  """
  def sources(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm table-zebra">
        <thead>
          <tr>
            <th>source</th>
            <th>feeds</th>
            <th>every</th>
            <th class="text-right">keys</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @sources} class={s.cell == @selected && "active"}>
            <td>
              <button
                type="button"
                phx-click="select"
                phx-value-cell={s.cell}
                class="link link-hover text-left"
              >
                <div class="font-medium"><%= s.origin || s.cell %></div>
                <div :if={s.origin} class="text-xs opacity-60"><%= s.cell %></div>
              </button>
            </td>
            <td class="text-xs opacity-70"><%= Enum.join(s.feeds, ", ") %></td>
            <td>
              <code :if={s.every} class="text-xs"><%= s.every %></code>
              <span :if={!s.every} class="text-xs opacity-40">on demand</span>
            </td>
            <td class="text-right tabular-nums" title={count_title(@status[s.cell])}>
              <%= key_count(@status[s.cell]) %>
            </td>
            <td class="text-right">
              <button
                class="btn btn-xs btn-ghost"
                phx-click="scan"
                phx-value-cell={s.cell}
                phx-value-mode="default"
              >
                scan
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:status, :map, required: true)
  attr(:selected, :string, default: nil)
  attr(:plan, :map, required: true)

  @doc """
  The hierarchy: what a change reaches, as an EXPRESSION.

  Each row renders the node as a function application —
  `reduce( folded: expenses ) by :category` — so an edge says what the input IS
  to the node reading it. A join's left and right are not interchangeable, a
  union's inputs are alternatives, and a bare arrow says neither.

  ## Why nested cards rather than indented rows

  This used to be flat `<li>`s pushed right by a `margin-left` computed from
  depth. That renders the same information and reads worse, because indentation
  alone is a weak signal: at four levels the eye cannot tell which ancestor a
  row belongs to, and nothing bounds a subtree.

  So a node is a bordered CARD, and its children nest INSIDE it — the older
  compliance portal's model tree, whose reasoning holds here. Containment is
  the structure, so no arithmetic encodes it: a subtree is visibly a region of
  the page rather than a run of rows that happen to start further right. The
  dashed rail down the children's edge is what makes a deep nest scannable, and
  the 4px kind-coloured spine on each card says what KIND of thing it is
  before you read the label.

  A cell reached by more than one route carries the stacked-card shadow — one
  glyph meaning "a set, not a single thing", the same one the SVG uses.

  Collapsed below depth 1 by default, with a child count on every collapsible
  row: a 7-deep graph is unreadable fully expanded, and a collapsed row with no
  count looks like a leaf.

  Toggling is `Phoenix.LiveView.JS` — a class flip in the browser, no server
  round-trip, so opening a branch costs nothing.
  """
  def hierarchy(assigns) do
    ~H"""
    <div class="rdd-tree">
      <div
        :for={row <- @rows}
        id={"row-#{row.path}"}
        class={["rdd-node rdd-kids", row.depth > 1 && "hidden"]}
      >
        <div
          class={[
            "rdd-row",
            row.routes > 1 && "rdd-many",
            row.id == @selected && "rdd-on"
          ]}
          style={"margin-left: #{row.depth * 26}px"}
        >
          <span class={["rdd-lead", lead_class(row)]}></span>

          <span
            :if={row.children > 0}
            class="rdd-chev font-mono text-xs opacity-40 cursor-pointer select-none"
            phx-click={toggle_kids(row)}
          >
            ▸
          </span>
          <span :if={row.children == 0} class="font-mono text-xs opacity-0">▸</span>

          <button type="button" phx-click="select" phx-value-cell={row.id} class="font-medium">
            <%= row.id %>
          </button>

          <span :if={row.children > 0} class="badge badge-ghost badge-xs">
            <%= row.children %>
          </span>

          <code :if={application(row)} class="text-xs opacity-70 min-w-0 break-all">
            <%= application(row) %>
          </code>

          <span
            :if={row.routes > 1 and not row.repeat?}
            class="badge badge-outline badge-xs shrink-0"
          >
            <%= row.routes %> routes
          </span>

          <span
            :if={row.repeat?}
            class="badge badge-ghost badge-xs shrink-0 italic"
            title="expanded under its other input"
          >
            also here
          </span>

          <span
            :for={{status, n} <- statuses(@status[row.id])}
            class={["badge badge-xs", status_class(status)]}
          >
            <%= status %> <%= n %>
          </span>

          <span
            class="text-xs opacity-50 tabular-nums ml-auto pl-3 shrink-0"
            title={count_title(@status[row.id])}
          >
            <%= key_count(@status[row.id]) %>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # The spine's colour says what KIND of node this is before the label is read:
  # where data ENTERS the graph, where it is COMBINED, and where it is merely
  # carried. Three kinds, because the library has three — inventing a colour per
  # operator would imply a taxonomy that does not exist.
  defp lead_class(%{cell: nil}), do: "rdd-lead-plain"

  defp lead_class(%{cell: cell}) do
    cond do
      cell.inputs == [] -> "rdd-lead-source"
      length(cell.inputs) > 1 -> "rdd-lead-join"
      true -> "rdd-lead-derive"
    end
  end

  # Collapse this row's whole subtree. Paths are prefixes — "r-0" contains
  # "r-0-1" and "r-0-1-2" — so one selector reaches every descendant.
  defp toggle_kids(row) do
    JS.toggle_class("rotate-90")
    |> JS.toggle(to: "[id^='row-#{row.path}-']")
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
    <div :if={@detail} class="card bg-base-200 mt-4">
      <div class="card-body p-4 gap-3">
        <div class="flex items-baseline gap-2 flex-wrap">
          <h2 class="card-title text-base"><%= @detail.id %></h2>

          <span :if={@detail.algebra.label} class="badge badge-ghost font-mono text-xs">
            <%= @detail.algebra.label %>
          </span>

          <a
            :if={@detail.implementation && @detail.implementation.url}
            href={@detail.implementation.url}
            target="_blank"
            rel="noopener"
            class="link link-hover text-xs opacity-70"
          >
            <%= short(@detail.implementation.module) %> ↗
          </a>
        </div>

        <p :if={NodeDetail.headline(@detail)} class="text-sm opacity-80">
          <%= NodeDetail.headline(@detail) %>
        </p>

        <div class="flex gap-4 flex-wrap text-xs">
          <div :if={@detail.inputs != []}>
            <span class="opacity-50">reads</span>
            <%= Enum.join(@detail.inputs, ", ") %>
          </div>
          <div :if={@detail.outputs != []}>
            <span class="opacity-50">feeds</span>
            <%= Enum.join(@detail.outputs, ", ") %>
          </div>
          <div :if={@detail.algebra.detail} class="font-mono opacity-60">
            <%= @detail.algebra.detail %>
          </div>
        </div>

        <div :if={@detail.steps != []} class="mt-1">
          <div class="text-xs uppercase tracking-wide opacity-50 mb-1">recent recomputes</div>
          <table class="table table-xs">
            <tbody>
              <tr :for={step <- @detail.steps}>
                <td class="tabular-nums"><%= ms(step.duration_us) %></td>
                <td class="tabular-nums"><%= length(step.changed) %> changed</td>
                <td class="opacity-60">
                  <span :if={step.triggered_by}>after <%= step.triggered_by %></span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@detail.steps == []} class="text-xs opacity-50">
          no recorded recomputes
        </p>

        <div :if={@detail.scanner} class="border-t border-base-300 pt-3 mt-1">
          <div class="text-xs uppercase tracking-wide opacity-50 mb-1">
            scanner
            <span :if={@detail.scanner.origin} class="normal-case opacity-70">
              · <%= @detail.scanner.origin[:label] %>
            </span>
          </div>

          <div class="flex gap-2 items-center flex-wrap">
            <button class="btn btn-xs" phx-click="scan" phx-value-cell={@detail.id} phx-value-mode="default">
              <%= if @detail.scanner.args != [], do: "quick scan", else: "run scan" %>
            </button>

            <button
              :if={@detail.scanner.args != []}
              class="btn btn-xs btn-outline"
              phx-click="scan"
              phx-value-cell={@detail.id}
              phx-value-mode="full"
              title="ignores the declared bound"
            >
              full scan
            </button>

            <code :if={@detail.scanner.every} class="text-xs opacity-60">
              every <%= @detail.scanner.every %>
            </code>
          </div>
        </div>

        <div :if={@detail.slices != []} class="border-t border-base-300 pt-3 mt-1">
          <div class="text-xs uppercase tracking-wide opacity-50 mb-1">reprocess</div>

          <div :for={slice <- @detail.slices} class="flex gap-2 items-center flex-wrap mb-1">
            <span class="text-xs opacity-60"><%= slice.label %></span>

            <button
              :for={value <- slice.values || []}
              class="btn btn-xs btn-ghost"
              phx-click="reprocess"
              phx-value-cell={@detail.id}
              phx-value-column={slice.column}
              phx-value-value={value}
            >
              <%= value %>
            </button>
          </div>

          <button
            class="btn btn-xs btn-outline"
            phx-click="reprocess"
            phx-value-cell={@detail.id}
            title="and everything below it"
          >
            whole cell
          </button>
        </div>
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
    <div class="overflow-x-auto border border-base-300 rounded-lg bg-base-200 p-2">
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
  defp status_class("present"), do: "badge-ghost"
  defp status_class(_other), do: "badge-warning badge-outline"

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
