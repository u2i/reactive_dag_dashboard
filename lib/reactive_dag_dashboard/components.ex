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
              <div class="font-medium"><%= s.origin || s.cell %></div>
              <div :if={s.origin} class="text-xs opacity-60"><%= s.cell %></div>
            </td>
            <td class="text-xs opacity-70"><%= Enum.join(s.feeds, ", ") %></td>
            <td>
              <code :if={s.every} class="text-xs"><%= s.every %></code>
              <span :if={!s.every} class="text-xs opacity-40">on demand</span>
            </td>
            <td class="text-right tabular-nums"><%= key_count(@status[s.cell]) %></td>
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
  The hierarchy: what a change reaches, drawn as structure.

  One row per step of the tree, indented by depth, each naming the operation it
  performs — the operator IS the relationship, and a bare arrow says nothing
  about whether an input is folded, joined or picked as one of several
  alternatives.
  """
  def hierarchy(assigns) do
    ~H"""
    <ul class="menu menu-sm w-full p-0">
      <li :for={row <- @rows}>
        <button
          type="button"
          phx-click="select"
          phx-value-cell={row.id}
          class={["flex items-baseline gap-2 py-1", row.id == @selected && "active"]}
          style={"padding-left: #{row.depth * 1.25 + 0.5}rem"}
        >
          <span class="font-mono text-xs opacity-30"><%= branch(row) %></span>
          <span class="font-medium"><%= row.id %></span>

          <span :if={op_label(row)} class="badge badge-ghost badge-xs font-mono">
            <%= op_label(row) %>
          </span>

          <span :if={row.routes > 1} class="badge badge-outline badge-xs">
            <%= row.routes %> routes
          </span>

          <span class="text-xs opacity-50 tabular-nums ml-auto">
            <%= key_count(@status[row.id]) %>
          </span>
        </button>
      </li>
    </ul>
    """
  end

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
      </div>
    </div>
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp branch(%{depth: 0}), do: ""
  defp branch(%{last?: true}), do: "└─"
  defp branch(_), do: "├─"

  defp op_label(row), do: ReactiveDagDashboard.Algebra.label(row.cell)

  defp short(mod) when is_atom(mod), do: mod |> Module.split() |> List.last()
  defp short(other), do: inspect(other)

  defp ms(us) when is_integer(us), do: "#{Float.round(us / 1000, 1)}ms"
  defp ms(_), do: "—"

  # three states, one of which is a problem. See NodeDetail / Insights `rows:`.
  defp key_count(nil), do: "?"
  defp key_count(%{rows: :unreadable}), do: "?"
  defp key_count(%{rows: :elsewhere}), do: "—"
  defp key_count(%{key_count: n}), do: n
end
