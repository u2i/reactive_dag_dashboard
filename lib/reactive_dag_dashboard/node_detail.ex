defmodule ReactiveDagDashboard.NodeDetail do
  @moduledoc """
  Everything worth knowing about one node, assembled once.

  The old drawer showed a node's id, its inputs and a key count — enough to
  confirm the node exists, not enough to understand what it does or whether it
  is working. Answering *"what processing is happening here"* needs four things,
  and all four are already available; nothing new has to be recorded:

    * **what it does** — the algebra (`reduce by :category`, `per_key
      :describe`) from the DSL, and for a `compute` node the first paragraph of
      its own moduledoc, which is usually a better description than a UI could
      invent. See `ReactiveDagDashboard.SourceLink`.
    * **where the code is** — derived from `module_info(:compile)[:source]` plus
      the doc annotation, so a reader goes from a name to the line.
    * **what it holds** — key count and status histogram, and WHY the count is
      what it is (`rows: :stored | :elsewhere | :unreadable`), so an empty table
      and a node that keeps its rows elsewhere are not both rendered as broken.
    * **what it recently did** — its steps from the retained drain reports:
      how long, how many keys, and what triggered it.

  The last one is the piece a graph picture cannot give you. A node that looks
  structurally fine and has not recomputed in a week is the interesting case,
  and it is invisible without history.
  """

  alias ReactiveDag.Insights
  alias ReactiveDagDashboard.{Algebra, SourceLink}

  @recent_steps 5

  @type t :: %{
          id: String.t(),
          status: map() | nil,
          algebra: %{label: String.t() | nil, detail: String.t() | nil, roles: map()},
          implementation: map() | nil,
          inputs: [String.t()],
          outputs: [String.t()],
          scanner: map() | nil,
          steps: [map()],
          last_run: DateTime.t() | nil
        }

  @doc """
  Assemble the detail for `cell_id`, or `nil` when the plan has no such cell.
  """
  @spec build(ReactiveDag.Plan.t(), String.t(), map()) :: t() | nil
  def build(plan, cell_id, controls \\ %{}) do
    case plan.cells[cell_id] do
      nil ->
        nil

      cell ->
        steps = recent_steps(cell_id)

        %{
          id: cell_id,
          status: Insights.cell_status(plan, cell_id),
          algebra: %{
            label: Algebra.label(cell),
            detail: Algebra.detail(cell),
            roles: Algebra.roles(cell)
          },
          implementation: SourceLink.describe(cell),
          inputs: cell.inputs,
          outputs: Map.get(plan.parents, cell_id, []) |> Enum.sort(),
          scanner: controls[cell_id],
          steps: steps,
          last_run: steps |> List.first() |> then(&(&1 && &1.at))
        }
    end
  end

  @doc """
  This cell's steps from the retained reports, newest first.

  A step per recompute, carrying what the drain already measured — duration,
  the keys claimed and changed, and which cell triggered it. That last field is
  the causal link a static graph cannot show: *this* recomputed because *that*
  moved.
  """
  @spec recent_steps(String.t(), pos_integer()) :: [map()]
  def recent_steps(cell_id, limit \\ @recent_steps) do
    Insights.recent(:all)
    |> Enum.flat_map(fn %{report: report, at: at} ->
      report.steps
      |> Enum.filter(&(&1.cell == cell_id))
      |> Enum.map(&Map.put(&1, :at, at))
    end)
    |> Enum.take(limit)
  end

  @doc """
  A one-line answer to "what is this node for", preferring the most specific
  thing available.

  The moduledoc when there is one, because a human wrote it about this node;
  the algebra otherwise, because `reduce by :category` still says more than the
  cell id does.
  """
  @spec headline(t()) :: String.t() | nil
  def headline(%{implementation: %{summary: summary}}) when is_binary(summary), do: summary
  def headline(%{algebra: %{label: label}}) when is_binary(label), do: label
  def headline(_), do: nil

  @doc """
  The graph's sources, one row per SCANNER — what feeds this graph.

  Grouped by scanner rather than listed per scanned cell. That is what fixes
  the duplicate heading: a source feeding two leaves used to print its origin
  twice, once above each cell, which read as two independent sources of the
  same name.

  Under source-as-node a scanner has one cell and `feeds` is its children. For
  a host that has not migrated — two leaves each declaring the same scanner —
  `feeds` is those leaves, and the source still appears once.
  """
  @spec sources(ReactiveDag.Plan.t(), map()) :: [map()]
  def sources(plan, controls) do
    controls
    |> Enum.group_by(fn {_id, c} -> c.source end)
    |> Enum.map(fn {module, entries} ->
      {cell, control} = entries |> Enum.sort_by(&elem(&1, 0)) |> hd()

      %{
        cell: cell,
        module: module,
        origin: control.origin && control.origin[:label],
        every: control.every,
        args: control.args,
        # every cell this scanner writes, plus what those cells feed — one
        # crawl's reach, however the host declared it
        feeds: feeds_of(plan, Enum.map(entries, &elem(&1, 0)))
      }
    end)
    |> Enum.sort_by(&(&1.origin || &1.cell))
  end

  defp feeds_of(plan, cells) do
    downstream = Enum.flat_map(cells, &Map.get(plan.parents, &1, []))

    (cells ++ downstream)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in cells and length(cells) == 1))
    |> Enum.sort()
  end
end
