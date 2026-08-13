defmodule ReactiveDagDashboard.FixtureGraph do
  @moduledoc """
  A real two-node reactive graph for the render tests — an Ets-backed leaf and a
  rollup over it.

  Deliberately real rather than a hand-built `%Plan{}`: the dashboard's job is to
  render whatever `ReactiveDag.Insights` reports, so the test is only meaningful
  if that data comes from the library actually reading resources. A stubbed plan
  would have kept passing through the 0.17 changes that removed the tuple store.
  """

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Expenses do
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets, extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :category, :string, public?: true
      attribute :amount, :float, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :upsert do
        upsert?(true)
        accept([:key, :category, :amount])
      end
    end

    reactive do
      id(:expenses)
      leaf?(true)
    end
  end

  # a verdict: an ordinary node with a :status column (0.17 removed `verdict? true`)
  defmodule CategoryHealth do
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets, extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :status, :string, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :upsert do
        upsert?(true)
        accept([:key, :status])
      end
    end

    reactive do
      id(:category_health)
      op(:check)

      reduce over: :expenses,
             group_by: :category,
             into: fn _cat, rows ->
               total = rows |> Enum.map(& &1.amount) |> Enum.sum()
               %{status: if(total < 100.0, do: "present", else: "failing")}
             end
    end
  end

  @doc "The plan, as the router's `:plan` MFA would return it."
  def plan, do: ReactiveDag.Node.graph([Expenses, CategoryHealth])

  @doc "Seed both cells so the page has real rows to report."
  def seed do
    for r <- [Expenses, CategoryHealth], row <- Ash.read!(r), do: Ash.destroy!(row)

    for {k, cat, amt} <- [{"e1", "travel", 500.0}, {"e2", "meals", 40.0}] do
      Expenses |> Ash.Changeset.for_create(:upsert, %{key: k, category: cat, amount: amt}) |> Ash.create!()
    end

    {:ok, _} = ReactiveDag.Node.Recompute.recompute(plan().cells["category_health"], ["*"])
    :ok
  end
end
