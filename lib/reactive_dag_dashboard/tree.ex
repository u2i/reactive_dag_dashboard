defmodule ReactiveDagDashboard.Tree do
  @moduledoc """
  The graph as a tree, in either direction — exploded by route, or collapsed
  to one row per cell.

  A DAG is not a tree: a cell reached by three paths is one cell, but it is
  three routes for a change to travel. The two questions an operator actually
  asks are directional, and both are about routes rather than nodes:

    * *from this leaf, where does a change go?* — `downstream/2`, following
      `plan.parents`
    * *what feeds this table?* — `upstream/2`, following each cell's `inputs`

  Both shapes are here, because they answer different questions and neither is
  a better version of the other:

    * `downstream/2` + `flatten/1` — **exploded**, a cell repeated once per
      route. Answers *what does changing this leaf COST*: three routes to a node
      is three recomputes, and collapsing hides that.
    * `levels/2` — **collapsed**, one row per cell banded by distance. Answers
      *where does this source LAND*, which is the question you have when
      tracking data through the graph rather than costing a change.

  The exploded shape was the only one for a while, and at real graph sizes it
  stops answering the second question at all: row count grows with paths rather
  than cells, so the same name recurs down the page, each occurrence marked a
  repeat without saying what it repeats from. `levels/2` turns that duplication
  into the useful fact — the row states every edge it arrives by.

  ## Cycles

  A `ReactiveDag.Plan` is acyclic by construction — `Graph.build/1` computes
  depths, which a cycle makes impossible. This module does not trust that:
  it carries the current path and refuses to descend into a cell already on it,
  marking the node `cyclic?`. A dashboard whose job is to explain a graph must
  not hang on a malformed one; better to render the cycle visibly.

  ## Shape

  Each node is a map, deliberately plain rather than a struct — it is passed
  straight to a template:

      %{
        id: "category_health",
        cell: %ReactiveDag.Cell{},
        depth: 1,          # depth in THIS tree, not the plan's depth
        via: "expenses",   # the edge we arrived by (nil at the root)
        repeat?: true,     # this id already appeared elsewhere in this tree
        cyclic?: false,
        children: [...]
      }
  """

  alias ReactiveDag.Plan

  @type node_t :: %{
          id: String.t(),
          cell: struct() | nil,
          depth: non_neg_integer(),
          via: String.t() | nil,
          repeat?: boolean(),
          cyclic?: boolean(),
          children: [node_t()]
        }

  @doc """
  Where a change to `id` travels: the full downstream expansion, one branch per
  propagation path.

  This is the leaf's-eye view — `dirties_on` fires on a row, and this is every
  recompute that follows.
  """
  @spec downstream(Plan.t(), String.t()) :: node_t()
  def downstream(%Plan{} = plan, id), do: build(plan, id, &parents_of(plan, &1))

  @doc """
  What feeds `id`: the full upstream expansion, one branch per input path.

  This is the derived-table view — the row in front of you is wrong, and this
  is everywhere it could have come from.
  """
  @spec upstream(Plan.t(), String.t()) :: node_t()
  def upstream(%Plan{} = plan, id), do: build(plan, id, &inputs_of(plan, &1))

  @doc """
  Every cell with no inputs — the roots of the downstream view.

  `leaf?` is a declaration and not every graph sets it, so a cell with no inputs
  counts too: it is a root of propagation whether or not it says so.
  """
  @spec roots(Plan.t()) :: [String.t()]
  def roots(%Plan{cells: cells}) do
    cells
    |> Map.values()
    |> Enum.filter(&(&1.leaf? == true or &1.inputs == []))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @doc """
  Every cell nothing consumes — the roots of the upstream view, and the tables a
  host actually queries.
  """
  @spec sinks(Plan.t()) :: [String.t()]
  def sinks(%Plan{cells: cells} = plan) do
    cells
    |> Map.keys()
    |> Enum.filter(&(parents_of(plan, &1) == []))
    |> Enum.sort()
  end

  @doc """
  Flatten a tree to a depth-first list — the order it renders in, so a template
  iterates once instead of recursing.
  """
  @spec flatten(node_t()) :: [node_t()]
  def flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]

  @doc "How many distinct paths this tree contains (its leaf count)."
  @spec path_count(node_t()) :: non_neg_integer()
  def path_count(%{children: []}), do: 1
  def path_count(%{children: children}), do: children |> Enum.map(&path_count/1) |> Enum.sum()

  @doc """
  The same reachable set as `flatten/1`, but **one row per cell** — the shape for
  tracking a source to where it lands.

  The exploded tree answers *"what does changing this leaf cost me"*, and repeats
  a cell once per route to do it. That is the right answer to that question and
  the wrong shape for this one: a graph with real fan-in has a row count that
  grows with PATHS, so the same name recurs down the page, each occurrence marked
  a repeat without saying what it repeats from. Following a source to its
  destinations then means holding a stack in your head and losing it at every
  convergence.

  Collapsing turns the duplication into the useful fact. Each cell appears once,
  at its greatest distance from the origin — so it never renders above something
  it depends on — and carries `via`, EVERY edge it arrives by:

      %{id: "all_verdicts", distance: 2, via: ["category_health", "spend_rollup"],
        cell: %Cell{}, routes: 2}

  `routes` is how many paths reach it, which is the number the exploded view was
  spending a row each on.

  Rows come back grouped and ordered by distance, so a template renders bands
  rather than indentation — the origin, then what it touches directly, then what
  that touches. Depth-as-padding stops being readable at about three levels; a
  band stays readable at any depth, because position no longer has to encode
  parentage when `via` states it.
  """
  @spec levels(Plan.t(), node_t()) :: [{non_neg_integer(), [map()]}]
  def levels(%Plan{}, tree) do
    tree
    |> flatten()
    |> Enum.reject(& &1.cyclic?)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, occurrences} ->
      %{
        id: id,
        cell: hd(occurrences).cell,
        # the FURTHEST occurrence: a cell reachable in one hop and also in three
        # sits below everything on the long route, or it would render above a
        # cell it depends on
        distance: occurrences |> Enum.map(& &1.depth) |> Enum.max(),
        via: occurrences |> Enum.map(& &1.via) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        routes: length(occurrences)
      }
    end)
    |> Enum.group_by(& &1.distance)
    |> Enum.map(fn {distance, rows} -> {distance, Enum.sort_by(rows, & &1.id)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # ── building ────────────────────────────────────────────────────────────────

  # `seen` spans the WHOLE tree (so a second path to a cell is marked a repeat),
  # while `path` is only the current branch (so only a real cycle stops descent).
  # Conflating them would prune legitimate fan-in as if it were a loop.
  defp build(plan, id, next) do
    {node, _seen} = walk(plan, id, next, 0, nil, MapSet.new(), MapSet.new())
    node
  end

  defp walk(plan, id, next, depth, via, seen, path) do
    cyclic? = MapSet.member?(path, id)
    repeat? = MapSet.member?(seen, id)
    seen = MapSet.put(seen, id)

    {children, seen} =
      if cyclic? do
        {[], seen}
      else
        path = MapSet.put(path, id)

        Enum.reduce(next.(id), {[], seen}, fn child, {acc, seen} ->
          {node, seen} = walk(plan, child, next, depth + 1, id, seen, path)
          {acc ++ [node], seen}
        end)
      end

    node = %{
      id: id,
      cell: plan.cells[id],
      depth: depth,
      via: via,
      repeat?: repeat?,
      cyclic?: cyclic?,
      children: children
    }

    {node, seen}
  end

  defp parents_of(%Plan{parents: parents}, id), do: parents |> Map.get(id, []) |> Enum.sort()

  defp inputs_of(%Plan{cells: cells}, id) do
    case cells[id] do
      nil -> []
      cell -> Enum.sort(cell.inputs)
    end
  end
end
