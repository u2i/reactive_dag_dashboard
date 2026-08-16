defmodule ReactiveDagDashboard.Algebra do
  @moduledoc """
  What a cell's `reactive` block actually SAYS, in renderable form.

  `Cell.inputs` is a flat list of ids, so every edge in the graph looks alike —
  and they are not alike. A `join`'s two inputs are not interchangeable: one is
  the left and one is the right. A `union`'s inputs are alternatives to each
  other. A `reduce`'s single input is folded by a named key. Drawing all three as
  the same anonymous arrow throws away the thing that makes the edge mean
  something, which is why a graph picture can be perfectly accurate and still
  tell you nothing about the relationship.

  The relationship IS the operator. So this reads the entity struct the extension
  already carries in `meta` — `%{reduce: %Reduce{}}`, `%{join: %Join{}}`, and so
  on — and reports:

    * `label` — the operation, as an author would say it: `"join on :account"`,
      `"reduce by :category"`, `"per_key :summarise"`.
    * `roles` — `%{input_id => role}`, what each input IS to this cell: `"left"`,
      `"right"`, `"alternative"`, `"folded"`.
    * `detail` — the qualifier worth showing under the node: the fingerprint a
      `per_key` compares, the fields a `join` matches on.

  Nothing here interprets the algebra; it only names it. A cell whose shape this
  does not recognise reports `nil` and renders as a plain node, which is the
  correct outcome for a `compute` module or a bare `run` — those are opaque by
  construction, and pretending otherwise would be inventing structure.
  """

  @doc """
  The operation label for a cell — what it DOES, or `nil` if it does not say.
  """
  @spec label(struct() | nil) :: String.t() | nil
  def label(nil), do: nil

  def label(cell) do
    cond do
      j = cell[:join] -> "join#{on(j)}"
      r = cell[:reduce] -> "reduce#{by(r)}"
      cell[:union] -> "union"
      pk = cell[:per_key] -> "per_key #{inspect(pk.action)}"
      a = cell[:aggregate] -> aggregate_label(a)
      act = cell[:run] -> "run #{inspect(act)}"
      # the module IS the operator: `compute MeetingJoin` says the same thing
      # twice, and the name is what a reader recognises
      cell[:compute] -> short(cell[:compute])
      cell[:leaf?] -> "leaf"
      true -> nil
    end
  end

  @doc """
  What each input IS to this cell, as `%{input_id => role}`.

  The roles a `join` gives its two sides are the clearest case — `left` and
  `right` are not decoration, they decide which row survives an outer join — but
  every operator has them, and a flat `inputs` list has never carried any.
  """
  @spec roles(struct() | nil) :: %{optional(String.t()) => String.t()}
  def roles(nil), do: %{}

  def roles(cell) do
    cond do
      j = cell[:join] ->
        join_roles(cell, j)

      # numbered, so two alternatives are distinguishable in the application:
      # `union( feed1: a · feed2: b )` rather than two identical labels
      cell[:union] ->
        cell.inputs |> Enum.with_index() |> Map.new(fn {id, i} -> {id, "feed#{i + 1}"} end)

      cell[:reduce] ->
        Map.new(cell.inputs, &{&1, "folded"})

      cell[:per_key] ->
        Map.new(cell.inputs, &{&1, "per row"})

      cell[:aggregate] ->
        Map.new(cell.inputs, &{&1, "counted"})

      true ->
        %{}
    end
  end

  @doc """
  The node as a function application: `op( role: input · role: input )`.

  A cell id and an operator name tell you what a node is called and what kind of
  thing it does. They do not tell you what each INPUT is to it, which is the
  fact that makes a graph legible: a join's left and right are not
  interchangeable, a union's inputs are alternatives, a reduce's single input is
  folded.

      join( left: budget_rollups · right: account_totals ) on :account
      union( feed1: category_health · feed2: spend_rollup )
      reduce( folded: expenses ) by :category
      per_key( per row: transcripts ) :summarise

  Borrowed from an older compliance portal, which rendered its own algebra this
  way. The roles are derived at render time from the operator and the input's
  position — nothing is stored on the edge, and nothing about the cell changes.
  """
  @spec application(struct() | nil) :: String.t() | nil
  def application(nil), do: nil

  def application(cell) do
    case {label(cell), args(cell)} do
      {nil, _} -> nil
      {op, ""} -> op
      {op, args} -> "#{head(op)}( #{args} )#{tail(op)}"
    end
  end

  # A `compute` module is OPAQUE — the library hands it a cell and keys and has
  # no idea what it does with them, so it cannot say what any input is FOR.
  #
  # Labelling them all `arg:` was worse than saying nothing: four inputs to a
  # MeetingJoin rendered as four identical roles, which reads as information and
  # is not. The module name IS the operator here, and the inputs are just its
  # arguments in order:
  #
  #     MeetingJoin( meeting_shell, agenda_items, meeting_events )
  #
  # A declarative node keeps named roles, because there the library really does
  # know: a join's left is the left.
  defp roled?(cell), do: not is_nil(cell[:compute])

  # `label/1` returns "reduce by :category"; the application splits it so the
  # qualifier trails the arguments — `reduce( folded: x ) by :category` reads as
  # the fold it is, where `reduce by :category( folded: x )` does not.
  defp head(label), do: label |> String.split(" ", parts: 2) |> hd()

  defp tail(label) do
    case String.split(label, " ", parts: 2) do
      [_only] -> ""
      [_head, rest] -> " #{rest}"
    end
  end

  defp args(cell) do
    if roled?(cell) do
      cell |> inputs() |> Enum.join(", ")
    else
      roles = roles(cell)

      cell
      |> inputs()
      |> Enum.map_join(" · ", fn input ->
        case Map.get(roles, input) do
          nil -> input
          role -> "#{role}: #{input}"
        end
      end)
    end
  end

  defp inputs(%{inputs: inputs}), do: inputs
  defp inputs(_), do: []

  @doc """
  The qualifier worth showing under a node — what it compares, matches, or keys
  on. `nil` when the operator has nothing further to say.
  """
  @spec detail(struct() | nil) :: String.t() | nil
  def detail(nil), do: nil

  def detail(cell) do
    cond do
      pk = cell[:per_key] -> fingerprint_detail(pk)
      r = cell[:reduce] -> group_detail(r)
      true -> nil
    end
  end

  # ── labels ──────────────────────────────────────────────────────────────────

  defp on(%{key: key}) when not is_nil(key) and is_atom(key), do: " on #{inspect(key)}"
  defp on(_), do: ""

  defp by(%{group_by: g}) when is_atom(g) and not is_nil(g), do: " by #{inspect(g)}"

  defp by(%{group_by: g}) when is_list(g) and g != [],
    do: " by #{Enum.map_join(g, ", ", &inspect/1)}"

  defp by(_), do: ""

  defp aggregate_label(%{kind: kind, relationship: rel}) when not is_nil(kind),
    do: "#{kind} over #{inspect(rel)}"

  defp aggregate_label(_), do: "aggregate"

  defp short(mod) when is_atom(mod), do: mod |> Module.split() |> List.last()
  defp short(other), do: inspect(other)

  # ── roles ───────────────────────────────────────────────────────────────────

  # A join names its sides by the ATTRIBUTE it reads from each, not by input id —
  # both sides usually come off one `over` node. So when the two sides are not
  # separately identifiable among `inputs`, say so once rather than guessing
  # which input is which.
  defp join_roles(cell, join) do
    case cell.inputs do
      [left, right] ->
        %{left => side_label(join.left, "left"), right => side_label(join.right, "right")}

      inputs ->
        Map.new(inputs, &{&1, "joined"})
    end
  end

  defp side_label(spec, default) when is_list(spec) do
    case Keyword.get(spec, :where) do
      nil -> default
      w -> "#{default} where #{Enum.map_join(w, ", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)}"
    end
  end

  defp side_label(_, default), do: default

  # ── detail ──────────────────────────────────────────────────────────────────

  defp fingerprint_detail(%{fingerprint: fp}) when is_list(fp) and fp != [],
    do: "fingerprint #{Enum.map_join(fp, ", ", &inspect/1)}"

  defp fingerprint_detail(%{fingerprint: fp}) when is_function(fp), do: "fingerprint fn"
  defp fingerprint_detail(_), do: nil

  defp group_detail(%{key_prefix: p}) when is_binary(p), do: ~s(keys prefixed "#{p}")
  defp group_detail(_), do: nil
end
