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

  A plan MAY contain a cycle, and as of `reactive_dag` 0.17.0-rc.61 it can do so
  deliberately: a node may declare `feedback :other`, a back-edge that
  propagates but is excluded from scheduling order. The motivating case is a
  meeting whose minutes announce future meetings — real in the graph, never real
  in time.

  This module already did the right thing when a cycle was assumed impossible:
  it carries the current path and refuses to descend into a cell already on it,
  marking the node `cyclic?`. That defence is now load-bearing rather than
  belt-and-braces. A dashboard whose job is to explain a graph must not hang on
  one; better to render the cycle visibly.

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

  This is the leaf's-eye view — `dirties_on` or `augmented_by` fires on a row,
  and this is every recompute that follows.
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

  @doc """
  One graph per shared cell, stacked — every cell drawn exactly ONCE.

  The third shape, and the one that scales. `downstream/2` draws a converging
  cell under every route that reaches it, which is honest about cost and
  unreadable at size: on the Red Hook graph, `meeting_docs` explodes to 64 rows
  for 17 distinct cells, with `search_documents` and `search_embeddings` each
  drawn 18 times. `levels/2` collapses that but drops the edges as structure.

  This keeps the structure and removes the duplication. Any cell reached by more
  than one route is HOISTED out of the tree into its own graph below; where it
  used to expand, the parent carries a link to it instead.

      GRAPH 1  meeting_docs
        ├─ agenda_items    → search_documents ↴
        └─ meeting_events  → search_documents ↴

      GRAPH 2  search_documents        ← referenced by agenda_items, meeting_events
        └─ search_embeddings

  Returns `{root, shared}` where `shared` is a list of
  `%{id, tree, referenced_by}`, ordered so a graph appears after everything
  that links to it. `referenced_by` is what lets the hoisted graph point back —
  a link that goes only one way leaves you scrolling to find who wanted it.

  ## What a hoisted node looks like in the main tree

  `hoisted?: true` and `children: []`. The children are not lost; they are in
  that cell's own graph. A renderer keys off `hoisted?` to draw a link rather
  than a chevron.

  ## Cycles

  A `feedback` edge means a cell can be its own ancestor. Hoisting helps here
  rather than hurting: the second arrival is a link, so the walk stops without
  needing the cycle check to catch it. `cyclic?` is still set when a cell is on
  the current path, because a self-referential graph should say so.
  """
  @spec hoisted(Plan.t(), String.t(), :upstream | :downstream) ::
          {node_t(), [%{id: String.t(), tree: node_t(), referenced_by: [String.t()]}]}
  def hoisted(%Plan{} = plan, id, direction \\ :downstream) do
    next = stepper(plan, direction)

    # Two passes. The first counts how many routes reach each cell, because
    # hoisting cannot be decided while walking — the second route to a cell is
    # only known after it arrives, and by then the first has already expanded.
    # ITERATIVE, because hoisting changes the counts. `verdict_audit` sits below
    # `all_verdicts` and is reached twice only BECAUSE all_verdicts is reached
    # twice; once all_verdicts becomes a link, verdict_audit has a single route
    # and must stay inline. Counting once marked it shared with an empty
    # `referenced_by` — a graph nothing pointed at.
    shared_ids = settle_shared(plan, id, next, MapSet.new())

    {root, refs} = hoist_walk(plan, id, next, 0, nil, shared_ids, MapSet.new(), %{})

    # Hoisted graphs are expanded with the SHARED SET MINUS THEMSELVES, so a
    # shared cell's own subtree can contain other shared cells as links. Without
    # the subtraction a graph would immediately link to itself.
    {trees, refs} =
      shared_ids
      |> Enum.sort()
      |> Enum.map_reduce(refs, fn sid, refs ->
        # THREAD the refs through every graph. Built per-walk and discarded,
        # they lost any referrer found inside a hoisted graph:
        # `projected_meetings` links to `meeting_shell`, and meeting_shell's
        # `referenced_by` listed only `meeting_docs` — so the backlink omitted
        # a route the page was actually drawing.
        {tree, refs} =
          hoist_walk(plan, sid, next, 0, nil, MapSet.delete(shared_ids, sid), MapSet.new(), refs)

        {{sid, tree}, refs}
      end)

    shared =
      Enum.map(trees, fn {sid, tree} ->
        %{
          id: sid,
          tree: tree,
          referenced_by: refs |> Map.get(sid, []) |> Enum.uniq() |> Enum.sort()
        }
      end)

    {root, shared}
  end

  # Settle the shared set. Each round counts arrivals in the tree as it would be
  # drawn GIVEN the current set — stopping at links — so a cell stays shared
  # only if it is STILL reached twice once its ancestors have been hoisted.
  #
  # The set SHRINKS, which is the part I got wrong twice. `verdict_audit` sits
  # below `all_verdicts` and is reached twice only because all_verdicts is;
  # once all_verdicts becomes a link, verdict_audit has one route and belongs
  # inline. Round 1 finds both, round 2 finds only all_verdicts — so taking the
  # UNION never converges, and an earlier version looped forever.
  #
  # Replacing the set with each round's finding does converge: the count is a
  # function of the set, so once a round reproduces its input the fixpoint is
  # reached. `max_rounds` is a backstop, not the mechanism — a graph that
  # oscillated would otherwise hang the page it exists to explain.
  defp settle_shared(plan, id, next, shared, rounds_left \\ 16) do
    # Count across EVERY graph that will be drawn — the main tree AND each
    # hoisted cell's own graph — because a cell reached once per graph is still
    # drawn twice on the page. Counting the main tree alone expanded
    # `meeting_shell` in both the root graph and `projected_meetings`', since
    # neither saw the other's arrival.
    roots = [id | Enum.sort(shared)]

    counts =
      Enum.reduce(roots, %{}, fn root, acc ->
        root
        |> then(&route_counts(plan, &1, next, MapSet.delete(shared, &1)))
        |> Map.merge(acc, fn _k, a, b -> a + b end)
      end)

    # A graph's own root is drawn by definition, so its self-arrival is not
    # evidence of sharing — but an arrival from ANOTHER graph is.
    found =
      for {cid, n} <- counts,
          cid != id,
          n - if(cid in roots, do: 1, else: 0) > 1,
          into: MapSet.new(),
          do: cid

    cond do
      MapSet.equal?(found, shared) -> shared
      rounds_left == 0 -> found
      true -> settle_shared(plan, id, next, found, rounds_left - 1)
    end
  end

  # How many routes reach each cell, treating anything in `shared` as a leaf —
  # because that is how it will be drawn. Counts ROUTES, not nodes.
  #
  # `root` is passed explicitly rather than inferred from the accumulator: an
  # earlier version stopped at "shared and not the first node counted", which
  # made the result depend on traversal order, so the set never settled and
  # `settle_shared/4` looped forever.
  defp route_counts(plan, id, next, shared) do
    count(plan, id, next, shared, id, MapSet.new(), %{})
  end

  defp count(plan, id, next, shared, root, path, acc) do
    acc = Map.update(acc, id, 1, &(&1 + 1))

    stop? = MapSet.member?(path, id) or (id != root and MapSet.member?(shared, id))

    if stop? do
      acc
    else
      path = MapSet.put(path, id)

      Enum.reduce(next.(id), acc, fn child, acc ->
        count(plan, child, next, shared, root, path, acc)
      end)
    end
  end

  defp hoist_walk(plan, id, next, depth, via, shared_ids, path, refs) do
    cyclic? = MapSet.member?(path, id)
    hoist? = MapSet.member?(shared_ids, id)

    # A hoisted node records WHO pointed at it and stops. `via` is the parent we
    # arrived from, which is exactly the backlink the hoisted graph needs.
    refs = if hoist? and via, do: Map.update(refs, id, [via], &[via | &1]), else: refs

    {children, refs} =
      if cyclic? or hoist? do
        {[], refs}
      else
        path = MapSet.put(path, id)

        Enum.reduce(next.(id), {[], refs}, fn child, {acc, refs} ->
          {node, refs} = hoist_walk(plan, child, next, depth + 1, id, shared_ids, path, refs)
          {acc ++ [node], refs}
        end)
      end

    node = %{
      id: id,
      cell: plan.cells[id],
      depth: depth,
      via: via,
      repeat?: false,
      cyclic?: cyclic?,
      hoisted?: hoist?,
      children: children
    }

    {node, refs}
  end

  defp stepper(plan, :upstream), do: &inputs_of(plan, &1)
  defp stepper(plan, _downstream), do: &parents_of(plan, &1)

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
  @spec nested(Plan.t(), node_t()) :: map()
  def nested(%Plan{} = plan, tree) do
    arrivals =
      tree
      |> flatten()
      |> Enum.reject(&(&1.cyclic? or is_nil(&1.via)))
      |> Enum.group_by(& &1.id, & &1.via)
      |> Map.new(fn {id, vias} -> {id, vias |> Enum.uniq() |> Enum.sort()} end)

    walk_nested(tree, arrivals, plan, 0, tree.id)
  end

  defp walk_nested(node, arrivals, plan, depth, path) do
    children = if node.cyclic?, do: [], else: node.children

    kids =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, i} ->
        walk_nested(child, arrivals, plan, depth + 1, "#{path}-#{i}")
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
      # Nothing starts closed. A scoped tree is small — the largest in a real
      # 33-cell graph is 29 rows and the median is 6 — so collapsing bought
      # nothing and cost the thing you came to read. The chevron still folds a
      # branch by hand when one is in the way.
      closed?: false,
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
