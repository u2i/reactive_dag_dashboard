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
  The roots grouped by the SCANNER that feeds them.

  A source can feed several leaves — one crawl of one site whose rows land in two
  cells — and the picker listing them side by side says nothing about that, so
  two halves of one crawl read as two independent sources.

  The pairing is a fact of the graph (`scan` on the leaf, verified at assembly
  against the scanner's own `leaf_cells/1`), so this is a `group_by` rather than
  a guess. Returns `{origin, scanner, [root_id]}` sorted by label, with unscanned
  roots last under `nil` — a leaf whose keys arrive some other way is not
  mis-grouped, it is simply not part of a crawl.

  `origin` is the scanner's own `origin/0` label where it offers one, so the
  group reads as *"City agenda center"* rather than as a module name.
  """
  @spec roots_by_scanner(Plan.t()) :: [{String.t() | nil, module() | nil, [String.t()]}]
  def roots_by_scanner(%Plan{cells: cells} = plan) do
    plan
    |> roots()
    |> Enum.group_by(&cells[&1].meta[:scan])
    |> Enum.map(fn {scanner, ids} -> {origin_label(scanner), scanner, Enum.sort(ids)} end)
    |> Enum.sort_by(fn {label, scanner, _ids} -> {is_nil(scanner), label || ""} end)
  end

  defp origin_label(nil), do: nil

  defp origin_label(mod) do
    with true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :origin, 0),
         %{label: label} <- mod.origin() do
      label
    else
      _ -> mod |> Module.split() |> List.last()
    end
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
  The hierarchy from one root: parent-child structure kept, convergence marked.

  A DAG is not a tree, and the two shapes either side of this both lose something
  to that fact. `flatten/1` repeats a converging cell once per route, so the same
  name recurs with no indication of what it repeats from. `levels/2` collapses it
  to one row and states its edges as text — which drops the edges as STRUCTURE,
  leaving you to match a name in one band against a `via` string in the next.

  This keeps the tree. Each cell's subtree is expanded exactly once, under the
  route that reaches it FURTHEST from the root — so nothing is drawn above a cell
  it depends on. Every other arrival becomes a leaf-level cross-reference: the
  edge is still drawn, it just does not re-expand what is already on the page.

      agenda_docs
      └─ agenda_items
         ├─ meeting
         │  └─ meetings          ← expanded here, the deepest route
         └─ meeting_summaries
            └─ meetings (above)  ← ref?: true, no subtree

  So a convergence renders as what it is: two edges arriving at one cell, both
  visible, one of them expanded. `arrivals` on the expanded row names every
  parent it is reached from, which is the fact `levels/2` had and the exploded
  tree did not.

  Rows come back depth-first with `depth`, `last?` (for drawing the rails) and
  `ref?`, ready for a template to iterate once.
  """
  @spec hierarchy(Plan.t(), node_t()) :: [map()]
  def hierarchy(%Plan{} = plan, tree) do
    # where each cell expands: its greatest depth, so its subtree sits below
    # everything it depends on. Ties break on the sorted parent, for stability.
    home =
      tree
      |> flatten()
      |> Enum.reject(& &1.cyclic?)
      |> Enum.group_by(& &1.id)
      |> Map.new(fn {id, occs} ->
        {id, occs |> Enum.map(&{&1.depth, &1.via}) |> Enum.max()}
      end)

    arrivals =
      tree
      |> flatten()
      |> Enum.reject(&(&1.cyclic? or is_nil(&1.via)))
      |> Enum.group_by(& &1.id, & &1.via)
      |> Map.new(fn {id, vias} -> {id, vias |> Enum.uniq() |> Enum.sort()} end)

    walk_hierarchy(tree, home, arrivals, plan, 0, true, [])
  end

  defp walk_hierarchy(node, home, arrivals, plan, depth, last?, acc) do
    expands_here? = Map.get(home, node.id) == {node.depth, node.via}

    row = %{
      id: node.id,
      cell: node.cell,
      depth: depth,
      via: node.via,
      last?: last?,
      cyclic?: node.cyclic?,
      # a second arrival: the edge is drawn, the subtree is not repeated
      ref?: not expands_here? and not node.cyclic?,
      arrivals: Map.get(arrivals, node.id, []),
      routes: length(Map.get(arrivals, node.id, []))
    }

    children = if expands_here? and not node.cyclic?, do: node.children, else: []
    last = length(children) - 1

    children
    |> Enum.with_index()
    |> Enum.reduce(acc ++ [row], fn {child, i}, acc ->
      walk_hierarchy(child, home, arrivals, plan, depth + 1, i == last, acc)
    end)
  end

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
