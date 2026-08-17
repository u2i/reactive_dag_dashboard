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
  The roots, each with the origin of the source that fetches it.

  This used to GROUP roots by scanner: a source feeding two leaves put both in
  one bucket, because listing them side by side said nothing about their being
  two halves of one crawl.

  A source is now a node, so that fan-out is graph structure — one root with two
  children — and the hierarchy below the picker shows it. What is left is
  labelling: a root reads better as *"Council portal"* than as `council_portal`,
  and only the source module knows its own name for itself.

  Returns `{origin, scanner, [root_id]}` to keep the picker's shape, with one
  root per entry and unscanned roots last under `nil`.
  """
  @spec roots_by_scanner(Plan.t()) :: [{String.t() | nil, module() | nil, [String.t()]}]
  def roots_by_scanner(%Plan{cells: cells} = plan) do
    plan
    |> roots()
    |> Enum.map(fn id ->
      scanner = cells[id].meta[:scan]
      {origin_label(scanner), scanner, [id]}
    end)
    |> Enum.sort_by(fn {label, scanner, [id]} -> {is_nil(scanner), label || id} end)
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
  Where a tree can START, for the question being asked.

  Downstream that is the SOURCES — "a change lands here, what breaks" enters
  where data enters. Upstream it is the OUTPUTS — "this table is wrong, where
  did it come from" starts at the table you are looking at.

  One list, not a taxonomy. An earlier version offered every cell grouped
  sources / derived / outputs, on the reasoning that a picker limited to the
  two ends could not root the tree at the middle of the graph. That was
  answering a question about the DATA STRUCTURE rather than about the work: a
  derived cell is not somewhere you begin, it is somewhere you arrive, and the
  end you cannot travel from is a dead end offered as a choice.

  The middle of the graph is still reachable — by clicking a name in the tree,
  which is how you get there when you have a reason to.
  """
  @spec starting_points(Plan.t(), :upstream | :downstream) :: [String.t()]
  def starting_points(plan, direction \\ :downstream)

  def starting_points(%Plan{} = plan, :upstream), do: sinks(plan)
  def starting_points(%Plan{} = plan, _downstream), do: roots(plan)

  @doc """
  Whether `id` has anything to show in `direction` — false at a dead end.

  A source has nothing above it and an output has nothing below it, so one
  direction of each is a single node with no tree. Rendering that as an empty
  panel reads as broken; the page asks first, and says which way to look
  instead.
  """
  @spec has_tree?(Plan.t(), String.t(), :upstream | :downstream) :: boolean()
  def has_tree?(%Plan{} = plan, id, :upstream), do: inputs_of(plan, id) != []
  def has_tree?(%Plan{} = plan, id, _downstream), do: parents_of(plan, id) != []

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
  The hierarchy from one root, expanded INLINE.

  A DAG is not a tree, and the two shapes either side of this both lose
  something to that. `levels/2` collapses a converging cell to one row and
  states its edges as text — which drops the edges as STRUCTURE, leaving you to
  match a name in one band against a `via` string in the next.

  This keeps the tree and draws a converging cell under EVERY route that reaches
  it, subtree and all. What sits under a parent is therefore everything that
  parent causes — no cross-reference to chase, no subtree parked elsewhere on
  the page:

      agenda_items
      ├─ meeting              [union]
      │  └─ meetings          [reduce by :id]
      │     └─ chains         [per_key]
      └─ meeting_summaries    [per_key]
         └─ meetings          [reduce by :id]
            └─ chains         [per_key]

  The cost is repetition, and it is the honest cost: those really are two
  recomputes of `meetings`, and a shape drawing it once implies a single unit of
  work. `arrivals` names every parent a cell is reached from and `routes` counts
  them, so a convergence stays legible without reading the whole tree.

  A cycle is still not descended into — that is a malformed graph rather than a
  convergence, and expanding it would not terminate.

  Rows come back depth-first with `depth` and `last?` (for drawing the rails),
  ready for a template to iterate once.
  """
  @spec hierarchy(Plan.t(), node_t()) :: [map()]
  def hierarchy(%Plan{} = plan, tree) do
    arrivals =
      tree
      |> flatten()
      |> Enum.reject(&(&1.cyclic? or is_nil(&1.via)))
      |> Enum.group_by(& &1.id, & &1.via)
      |> Map.new(fn {id, vias} -> {id, vias |> Enum.uniq() |> Enum.sort()} end)

    # Rooted at the tree's OWN id, not a constant: the page renders one tree per
    # source, and a shared root prefix collides in the DOM — LiveView rejects
    # duplicate ids outright.
    walk_hierarchy(tree, arrivals, plan, 0, true, [], tree.id)
  end

  @doc """
  The same rows as `hierarchy/2`, but NESTED — each row keeps its `kids`.

  `hierarchy/2` pre-walks the tree into a flat list and encodes depth as a
  number, which a template turns back into indentation. That renders the right
  information and loses the containment: a subtree becomes a run of rows that
  happen to start further right, with nothing bounding it, and at four levels
  the eye cannot tell which ancestor a row belongs to.

  Keeping the structure lets the markup nest too — a children wrapper inside its
  parent, which can carry the rail that makes a deep tree scannable. Depth stops
  being arithmetic and becomes what it already was.

  Rows carry the same fields, plus `kids` (the nested children) and `closed?`
  (collapsed below depth 1, as before). `children` remains the COUNT, because a
  collapsed row still has to say how much is folded under it.
  """
  @spec nested(Plan.t(), node_t(), :upstream | :downstream) :: map()
  def nested(plan, tree, direction \\ :downstream)

  def nested(%Plan{} = plan, tree, direction) do
    arrivals =
      tree
      |> flatten()
      |> Enum.reject(&(&1.cyclic? or is_nil(&1.via)))
      |> Enum.group_by(& &1.id, & &1.via)
      |> Map.new(fn {id, vias} -> {id, vias |> Enum.uniq() |> Enum.sort()} end)

    walk_nested(tree, arrivals, plan, 0, tree.id, open_depth(direction))
  end

  # How deep to render EXPANDED, which is a different answer per direction.
  #
  # Downstream fans out: one source reaches twenty cells, so depth 1 is a
  # summary and anything more is a wall. Upstream narrows to a chain — "what
  # feeds this, and what fed that" — and the answer is usually several levels
  # up, so collapsing it hides the whole point. Rendered collapsed, upstream
  # showed a root and two closed rows and read as having no hierarchy at all.
  defp open_depth(:upstream), do: :infinity
  defp open_depth(_downstream), do: 1

  defp walk_nested(node, arrivals, plan, depth, path, open_to) do
    children = if node.cyclic?, do: [], else: node.children

    kids =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, i} ->
        walk_nested(child, arrivals, plan, depth + 1, "#{path}-#{i}", open_to)
      end)

    %{
      id: node.id,
      cell: node.cell,
      depth: depth,
      via: node.via,
      cyclic?: node.cyclic?,
      repeat?: node.repeat? and not node.cyclic?,
      arrivals: Map.get(arrivals, node.id, []),
      routes: length(Map.get(arrivals, node.id, [])),
      children: length(children),
      # see `open_depth/1`: downstream fans out and collapses below depth 1,
      # upstream is a chain and renders open
      closed?: children != [] and open_to != :infinity and depth >= open_to,
      kids: kids,
      path: path
    }
  end

  defp walk_hierarchy(node, arrivals, plan, depth, last?, acc, path) do
    row = %{
      id: node.id,
      cell: node.cell,
      depth: depth,
      via: node.via,
      last?: last?,
      cyclic?: node.cyclic?,
      # already drawn in full elsewhere on this page — the subtree is suppressed
      # here, not the row
      repeat?: node.repeat? and not node.cyclic?,
      arrivals: Map.get(arrivals, node.id, []),
      routes: length(Map.get(arrivals, node.id, [])),
      # how many nodes read this one. Rendered as a pill so a COLLAPSED row
      # still says how much is folded under it — a collapsed node with no count
      # looks like a leaf, which is the failure mode of collapsing by default.
      children: length(node.children),
      # a stable id for the collapse toggle, unique per PATH rather than per
      # cell: an inline-expanded node appears more than once, and collapsing one
      # occurrence must not collapse the others.
      path: path
    }

    # A cycle is still not descended into: that is a malformed graph rather than
    # a convergence, and expanding it would not terminate.
    children = if node.cyclic?, do: [], else: node.children
    last = length(children) - 1

    children
    |> Enum.with_index()
    |> Enum.reduce(acc ++ [row], fn {child, i}, acc ->
      walk_hierarchy(child, arrivals, plan, depth + 1, i == last, acc, "#{path}-#{i}")
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
        via:
          occurrences
          |> Enum.map(& &1.via)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort(),
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
