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

  Collapsed below depth 1 by default, with a child count on every collapsible
  row: a 7-deep graph is unreadable fully expanded, and a collapsed row with no
  count looks like a leaf.

  Toggling is `Phoenix.LiveView.JS` — a class flip in the browser, no server
  round-trip, so opening a branch costs nothing.
  """
  def hierarchy(assigns) do
    ~H"""
    <ul class="menu menu-sm w-full p-0 gap-0">
      <li :for={row <- @rows} id={"row-#{row.path}"} class={["rdd-kids", row.depth > 1 && "hidden"]}>
        <div
          class={[
            "flex items-baseline gap-2 py-1 px-2 rounded",
            row.id == @selected && "bg-base-300",
            row.routes > 1 && "rdd-many"
          ]}
          style={"margin-left: #{row.depth * 1.25}rem"}
        >
          <span
            :if={row.children > 0}
            class="rdd-chev font-mono text-xs opacity-40 cursor-pointer"
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
      </li>
    </ul>
    """
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
  attr(:edges, :list, required: true)
  attr(:status, :map, required: true)
  attr(:selected, :string, default: nil)
  attr(:plan, :map, required: true)

  @doc """
  The graph as a drawn diagram: values as boxes, OPERATIONS as diamonds between
  them.

  The tree answers *"what does a change here reach"* and repeats a cell once per
  route to do it. This answers *"what is the shape of the whole thing"* — two
  routes converging are two lines meeting, drawn once.

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

  Columns come from the graph's own depth — `Insights.levels/1` is already
  longest-path-from-a-leaf, which IS the layered assignment, so there is no
  layout algorithm here.
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

  # Boxes on the depth columns; a diamond in the GAP before each derived cell,
  # where its inputs converge. Edges then run input → diamond → box, so the
  # operation sits on the path rather than being implied by it.
  defp geometry(levels, plan) do
    boxes =
      for {{_depth, cells}, col} <- Enum.with_index(levels),
          {cell, row} <- Enum.with_index(cells),
          into: %{} do
        {cell.id,
         %{
           id: cell.id,
           x: @pad + col * (@col_w + @col_gap),
           y: @pad + row * (@row_h + @row_gap),
           w: @col_w,
           h: @row_h,
           col: col
         }}
      end

    ops = for {id, box} <- boxes, box.col > 0, op = op_for(plan, id, box), do: op

    %{
      boxes: Enum.map(boxes, fn {_id, b} -> decorate(b, plan) end),
      ops: ops,
      segments: segments(plan, boxes, ops),
      width: @pad * 2 + length(levels) * (@col_w + @col_gap),
      height: @pad * 2 + tallest(levels) * (@row_h + @row_gap)
    }
  end

  defp tallest(levels),
    do: levels |> Enum.map(fn {_d, c} -> length(c) end) |> Enum.max(fn -> 1 end)

  defp decorate(box, plan) do
    Map.merge(box, %{
      many?: length(Map.get(plan.parents, box.id, [])) > 1,
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
  defp segments(plan, boxes, ops) do
    by_id = Map.new(ops, &{&1.id, &1})

    into_ops =
      for {to, op} <- by_id,
          from <- Map.get(plan.cells[to] || %{inputs: []}, :inputs, []),
          b = boxes[from],
          do: %{d: curve(b.x + b.w, b.y + @row_h / 2, op.cx - @op_r, op.cy), hot?: false}

    out_of_ops =
      for {to, op} <- by_id, b = boxes[to] do
        %{d: curve(op.cx + @op_r, op.cy, b.x, b.y + @row_h / 2), hot?: false}
      end

    into_ops ++ out_of_ops
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
