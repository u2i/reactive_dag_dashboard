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
      cell[:compute] -> "compute #{short(cell[:compute])}"
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
      j = cell[:join] -> join_roles(cell, j)
      cell[:union] -> Map.new(cell.inputs, &{&1, "alternative"})
      cell[:reduce] -> Map.new(cell.inputs, &{&1, "folded"})
      cell[:per_key] -> Map.new(cell.inputs, &{&1, "per row"})
      cell[:aggregate] -> Map.new(cell.inputs, &{&1, "counted"})
      true -> %{}
    end
  end

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
