defmodule ReactiveDagDashboard.AlgebraTest do
  @moduledoc """
  Reading the `reactive` block's algebra back out for display.

  The complaint this answers: a graph picture drew every edge the same way, so it
  could be entirely accurate and still say nothing about the relationship. The
  relationship is the OPERATOR — a join's left and right are not
  interchangeable, a union's inputs are alternatives, a reduce's input is folded.
  `Cell.inputs` is a flat list and carries none of that; the entity struct in
  `meta` carries all of it.
  """
  use ExUnit.Case, async: true

  alias ReactiveDagDashboard.{Algebra, FixtureGraph}

  setup_all do
    {:ok, plan: FixtureGraph.plan()}
  end

  defp cell(plan, id), do: plan.cells[id]

  describe "label/1 — what the cell does" do
    test "a reduce names the key it folds by", %{plan: plan} do
      assert Algebra.label(cell(plan, "category_health")) == "reduce by :category"
    end

    test "a union says so", %{plan: plan} do
      assert Algebra.label(cell(plan, "all_verdicts")) == "union"
    end

    test "a per_key names its action", %{plan: plan} do
      assert Algebra.label(cell(plan, "expense_notes")) == "per_key :describe"
    end

    test "a leaf is a leaf", %{plan: plan} do
      assert Algebra.label(cell(plan, "expenses")) == "leaf"
    end

    test "a cell that says nothing reports nil rather than inventing a label" do
      assert Algebra.label(nil) == nil
    end
  end

  describe "roles/1 — what each input IS" do
    test "a union's inputs are alternatives to each other", %{plan: plan} do
      roles = Algebra.roles(cell(plan, "all_verdicts"))

      assert roles["category_health"] == "alternative"
      assert roles["spend_rollup"] == "alternative"
    end

    test "a reduce folds its input", %{plan: plan} do
      assert Algebra.roles(cell(plan, "category_health")) == %{"expenses" => "folded"}
    end

    test "a per_key runs per row of its input", %{plan: plan} do
      assert Algebra.roles(cell(plan, "expense_notes")) == %{"expenses" => "per row"}
    end

    test "a leaf has no inputs and therefore no roles", %{plan: plan} do
      assert Algebra.roles(cell(plan, "expenses")) == %{}
    end
  end

  describe "detail/1 — the qualifier worth showing" do
    test "a per_key names what it compares", %{plan: plan} do
      assert Algebra.detail(cell(plan, "expense_notes")) == "fingerprint :amount"
    end

    test "an operator with nothing further to say reports nil", %{plan: plan} do
      refute Algebra.detail(cell(plan, "all_verdicts"))
    end
  end

  test "an unrecognised cell renders as a plain node, not a wrong one" do
    # a `compute` module or a bare `run` is opaque by construction; claiming
    # structure for it would be inventing structure
    opaque = %ReactiveDag.Cell{id: "x", inputs: ["a"], meta: %{}}

    assert Algebra.label(opaque) == nil
    assert Algebra.roles(opaque) == %{}
    assert Algebra.detail(opaque) == nil
  end
end
