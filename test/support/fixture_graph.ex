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
      scan(ReactiveDagDashboard.FixtureGraph.ExpenseScan, args: [recent: true], every: "0 * * * *")
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

  # a SECOND consumer of the same leaf, and a union over both — so the graph has
  # real fan-out, real fan-in, and a diamond. A tree view over a graph without
  # them proves nothing about how it handles repeated paths.
  defmodule SpendRollup do
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
      id(:spend_rollup)
      op(:fold)

      reduce over: :expenses,
             group_by: :category,
             into: fn _cat, rows ->
               %{status: if(length(rows) > 1, do: "present", else: "thin")}
             end
    end
  end

  # the diamond's tip: both consumers feed it, so it is reached by TWO paths
  # from `expenses`
  defmodule AllVerdicts do
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets, extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute :check, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :subject, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :status, :string, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :upsert do
        upsert?(true)
        accept([:check, :subject, :status])
      end
    end

    reactive do
      id(:all_verdicts)

      union from: [:category_health, :spend_rollup],
            into: [check: :cell, subject: :key, status: :status]
    end
  end

  defmodule ExpenseScan do
    @behaviour ReactiveDag.Source

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def polls, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def id, do: :expense_scan
    @impl true
    def leaf_cells(_g), do: ["expenses"]
    @impl true
    def origin, do: %{label: "Finance export"}
    @impl true
    def poll(opts) do
      if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &[opts | &1])

      # a deep pass reaches an upstream the cheap one never touches, and that
      # upstream is down — the shape a real crawler hits on a full crawl
      unreachable = if opts[:recent] == false, do: [{"archive", :timeout}], else: []

      # a cheap pass sees the rows it always sees; the deep pass reaches an
      # archive that is down and therefore reports nothing new
      changed = if unreachable == [], do: ["e1"], else: []

      {:ok, %{changed: changed, unreachable: unreachable}}
    end
  end

  @doc "The plan, as the router's `:plan` MFA would return it."
  def plan, do: ReactiveDag.Node.graph([Expenses, CategoryHealth, SpendRollup, AllVerdicts])

  # recompute/2 returns {:ok, changed} or {:ok, changed, meta} depending on the
  # node shape; normalise so the seed does not care which.
  defp maybe_meta({:ok, changed}), do: {:ok, changed, %{}}
  defp maybe_meta({:ok, changed, meta}), do: {:ok, changed, meta}

  @doc "Seed every cell so the page has real rows to report."
  def seed do
    for r <- [Expenses, CategoryHealth, SpendRollup, AllVerdicts],
        row <- Ash.read!(r),
        do: Ash.destroy!(row)

    for {k, cat, amt} <- [{"e1", "travel", 500.0}, {"e2", "meals", 40.0}] do
      Expenses |> Ash.Changeset.for_create(:upsert, %{key: k, category: cat, amount: amt}) |> Ash.create!()
    end

    p = plan()

    for id <- ["category_health", "spend_rollup", "all_verdicts"] do
      {:ok, _, _} = maybe_meta(ReactiveDag.Node.Recompute.recompute(p.cells[id], ["*"]))
    end

    :ok
  end
end
