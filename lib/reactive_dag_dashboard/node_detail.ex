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
    * **what counts as a change** — which columns the payload write compares
      when it decides a key moved. See `compare/1`.

  The fourth is the piece a graph picture cannot give you. A node that looks
  structurally fine and has not recomputed in a week is the interesting case,
  and it is invisible without history.

  The fifth is the missing half of the fourth's `changed` count. A step saying
  *40 keys changed* is only half an answer while "changed" is undefined, and it
  is the first thing you want when a cascade fires and nothing looks different.
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
          slices: [map()],
          compare: %{
            basis: :compare | :fingerprint | :every_column,
            columns: [atom()] | nil,
            inert: boolean()
          },
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
          # what a human may select this node by — the unit a PERSON picks,
          # which is rarely the unit a change invalidates
          slices: ReactiveDag.Node.Rows.slices(cell),
          # ...and the unit that DOES invalidate: what counts as a change
          compare: compare(cell),
          steps: steps,
          last_run: steps |> List.first() |> then(&(&1 && &1.at))
        }
    end
  end

  @doc """
  What makes a key count as CHANGED — the other half of a step's `changed` count.

  A recompute produces a row per key; the payload write then decides whether
  that row MOVED, and only a moved row propagates. Which columns it consults is
  a declaration, and three different answers are possible — so the reader gets
  the basis, not just a list:

    * `:compare` — the node declared `compare [...]`, and those columns and no
      others constitute its result. The rest are part of the RECORD without
      being part of the answer: `doc_id` (provenance), `ordinal` (position,
      which a re-parse shifts without anything actually changing).
    * `:fingerprint` — the node declared a top-level `fingerprint`, which
      stores a digest and compares that instead. It is what a source-fed LEAF
      wants, whose row carries fields that move on every observation
      (`last_seen_at`, an `etag` a server re-issues), and
      `ReactiveDag.Node.Payload` gives it precedence when a node declares both.
    * `:input_fingerprint` — a `per_key` node's own `fingerprint:`, which is a
      DIFFERENT mechanism wearing the same word. It is an input skip: the row's
      declared inputs are hashed and the action is not re-run when they have
      not moved. `ReactiveDag.Node.Recompute.PerKey` then writes with
      `Ash.create!` directly rather than through `Payload`, so neither
      `compare` nor the payload fingerprint is consulted on that path at all.
      Reporting it as either would be wrong about which code decides.
    * `:every_column` — the node declared neither, so every field the row
      carries is compared. That is right when every field is part of the
      answer, and it is an ANSWER rather than an absence: rendering nothing
      here would read as "unknown" to someone asking why a cascade fired.

  `inert: true` marks the case where a declaration buys nothing. A node whose
  computation is a single `aggregate` has its row built by
  `ReactiveDag.Node.Recompute.Aggregate.project/3` from the key column plus that
  one aggregate's `dest` — there is no bookkeeping column to narrow past, so
  `compare` cannot exclude anything. Two or more aggregates and it bites again
  (a `count` that moves while an `avg` does not), which is why the test is on
  the number of aggregates and not merely on the node being one.

  Read from `cell.meta[:compare]`, the same public meta `Rows.slices/1` reads —
  the library exposes no `Rows.compare/1`.
  """
  @spec compare(ReactiveDag.Cell.t()) :: %{
          basis: :compare | :fingerprint | :input_fingerprint | :every_column,
          columns: [atom()] | nil,
          inert: boolean()
        }
  def compare(%{meta: meta}) do
    declared = meta[:compare]

    cond do
      # Payload's own precedence, not ours: a node declaring both compares the
      # digest, so reporting the `compare` list would name columns the write
      # never consults.
      not is_nil(meta[:fingerprint]) ->
        %{basis: :fingerprint, columns: fingerprint_columns(meta[:fingerprint]), inert: false}

      fp = per_key_fingerprint(meta) ->
        %{basis: :input_fingerprint, columns: fingerprint_columns(fp), inert: false}

      is_list(declared) and declared != [] ->
        %{basis: :compare, columns: declared, inert: inert_aggregate?(meta)}

      true ->
        %{basis: :every_column, columns: nil, inert: false}
    end
  end

  def compare(_cell), do: %{basis: :every_column, columns: nil, inert: false}

  # `fingerprint` is either the input fields it hashes or a `(row -> value)`
  # function. Only the first names columns; a function is opaque and says so by
  # carrying none.
  defp fingerprint_columns(fields) when is_list(fields), do: fields
  defp fingerprint_columns(_), do: nil

  # A `per_key`'s fingerprint lives on the ENTITY, not in the top-level meta —
  # the two are different mechanisms that happen to share a word.
  defp per_key_fingerprint(%{per_key: %{fingerprint: fp}}) when not is_nil(fp), do: fp
  defp per_key_fingerprint(_meta), do: nil

  # A single `aggregate` projects the key column plus that aggregate's `dest`
  # and nothing else — nothing for `compare` to narrow past.
  defp inert_aggregate?(%{aggregate: %{} = agg}), do: aggregate_count(agg) < 2
  defp inert_aggregate?(_meta), do: false

  defp aggregate_count(agg) do
    ReactiveDag.Node.Recompute.Declarative.fold_kinds()
    |> Enum.map(&Map.get(agg, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      spec when is_list(spec) -> length(spec)
      _dest -> 1
    end)
    |> Enum.sum()
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
