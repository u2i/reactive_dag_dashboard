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
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:category, :string, public?: true)
      attribute(:amount, :float, public?: true)
      attribute(:fiscal_year, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :upsert do
        upsert?(true)
        accept([:key, :category, :amount, :fiscal_year])
      end
    end

    reactive do
      id(:expenses)
      leaf?(true)

      # `poll_as:` DIFFERS from the column on purpose: a scanner's option is its
      # own vocabulary, and a fixture where the two agree could not tell a
      # working translation from no translation at all
      slice(:fiscal_year, values: ["FY24", "FY25"], poll_as: :fiscal)

      poll(ReactiveDagDashboard.FixtureGraph.ExpenseScan,
        args: [recent: true],
        every: "0 * * * *"
      )
    end
  end

  # a verdict: an ordinary node with a :status column (0.17 removed `verdict? true`)
  defmodule CategoryHealth do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :upsert do
        upsert?(true)
        accept([:key, :status])
      end
    end

    reactive do
      id(:category_health)
      op(:check)

      reduce(
        over: :expenses,
        group_by: :category,
        into: fn _cat, rows ->
          total = rows |> Enum.map(& &1.amount) |> Enum.sum()
          %{status: if(total < 100.0, do: "present", else: "failing")}
        end
      )
    end
  end

  # a SECOND consumer of the same leaf, and a union over both — so the graph has
  # real fan-out, real fan-in, and a diamond. A tree view over a graph without
  # them proves nothing about how it handles repeated paths.
  defmodule SpendRollup do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :upsert do
        upsert?(true)
        accept([:key, :status])
      end
    end

    reactive do
      id(:spend_rollup)
      op(:fold)

      reduce(
        over: :expenses,
        group_by: :category,
        into: fn _cat, rows ->
          %{status: if(length(rows) > 1, do: "present", else: "thin")}
        end
      )
    end
  end

  # the diamond's tip: both consumers feed it, so it is reached by TWO paths
  # from `expenses`
  defmodule AllVerdicts do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:check, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:subject, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :upsert do
        upsert?(true)
        accept([:check, :subject, :status])
      end
    end

    reactive do
      id(:all_verdicts)

      union(
        from: [:category_health, :spend_rollup],
        into: [check: :cell, subject: :key, status: :status]
      )
    end
  end

  # BELOW the diamond's tip — so the converging cell has a subtree, and
  # "expanded inline" is distinguishable from "expanded once". Without this,
  # suppressing a repeat's children removes nothing and no test can tell.
  defmodule VerdictAudit do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key, :status])
    end

    reactive do
      id(:verdict_audit)

      reduce(
        over: :all_verdicts,
        group_by: :status,
        into: fn status, rows -> %{key: status, status: "#{length(rows)} seen"} end
      )
    end
  end

  # No table BY DESIGN — the write-elsewhere / escape-hatch shape. Nothing to
  # count here is not a failure to count, and the dashboard must not dress it as
  # one.
  #
  # Hung off `unscanned` (its own isolated root) rather than the diamond, so the
  # structural counts every other test asserts stay put. A shared fixture is
  # load-bearing; growing the part under test should not renumber the rest.
  defmodule Published do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [ReactiveDag.Node]

    reactive do
      id(:published)
      depends_on([:unscanned])
      compute(ReactiveDagDashboard.FixtureGraph.NoopOp)
    end
  end

  defmodule NoopOp do
    @behaviour ReactiveDag.Op
    @impl true
    def recompute(_cell, _keys), do: {:ok, []}
  end

  # A FINGERPRINTED node — the shape a reprocess has to defeat.
  #
  # `per_key` skips rows whose declared inputs have not moved, and after a prompt
  # change they have not. So a reprocess that only marks claims the keys and
  # changes nothing. Without a node of this shape in the fixture, the page's
  # reprocess control could be wired to a no-op and every test would still pass.
  defmodule ExpenseNotes do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:fiscal_year, :string, public?: true)
      attribute(:note, :string, public?: true)
      attribute(:fingerprint, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, update: [:note, :fingerprint, :fiscal_year]])

      create :upsert do
        upsert?(true)
        accept([:key, :fiscal_year, :note, :fingerprint])
      end

      action :describe, :map do
        argument(:amount, :float, allow_nil?: true)
        argument(:fiscal_year, :string, allow_nil?: true)

        run(fn input, _ ->
          ReactiveDagDashboard.FixtureGraph.Notes.record(input.arguments.amount)

          {:ok,
           %{
             "note" => "spent #{input.arguments.amount}",
             "fiscal_year" => input.arguments.fiscal_year
           }}
        end)
      end
    end

    reactive do
      id(:expense_notes)
      recompute_by(:key, to: :expenses, from: :key)
      slice(:fiscal_year, values: ["FY24", "FY25"])

      per_key(:describe,
        args: [amount: :amount, fiscal_year: :fiscal_year],
        fingerprint: [:amount],
        into: [note: :note, fiscal_year: :fiscal_year]
      )
    end
  end

  # Counts how many times the per_key action actually ran, which is the only
  # honest evidence that a reprocess did work rather than merely claiming keys.
  defmodule Notes do
    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def record(v), do: if(Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &[v | &1]))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
  end

  # A node that declares `compare` — the row carries provenance (`doc_id`) and
  # position (`ordinal`) that are part of the RECORD without being part of the
  # result. Without a node of this shape in the fixture, the drawer's
  # "counts as changed" section could report every node as comparing everything
  # and every test would still pass.
  defmodule ExpenseProvenance do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:status, :string, public?: true)
      # provenance and position: a re-parse shifts the ordinal without anything
      # about the ANSWER having moved
      attribute(:doc_id, :string, public?: true)
      attribute(:ordinal, :integer, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key, :status, :doc_id, :ordinal])
    end

    reactive do
      id(:expense_provenance)
      compare([:status])

      reduce(
        over: :expenses,
        group_by: :category,
        into: fn _cat, rows ->
          %{status: "#{length(rows)} seen", doc_id: "d1", ordinal: length(rows)}
        end
      )
    end
  end

  # A source-fed LEAF declaring a top-level `fingerprint` — the OTHER
  # mechanism, and the one that outranks `compare` in `Payload.moved?`. Its row
  # carries a `last_seen_at` that moves on every observation without the
  # observation having changed, which is exactly what a digest exists to ignore.
  defmodule Watched do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:body, :string, public?: true)
      attribute(:last_seen_at, :utc_datetime, public?: true)
      attribute(:fingerprint, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key, :body, :last_seen_at, :fingerprint])
    end

    reactive do
      id(:watched)
      leaf?(true)
      fingerprint([:body])
    end
  end

  # A SINGLE-aggregate node — the case where `compare` is INERT.
  #
  # `Aggregate.project/3` builds the row from the key column plus each
  # aggregate's `dest` and nothing else, so with one aggregate there is no
  # bookkeeping column for `compare [:spend_count]` to narrow past. The
  # declaration is real and does nothing, and the drawer must not show it as if
  # it were live.
  defmodule ExpenseTally do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:spend_count, :integer, public?: true)
    end

    relationships do
      has_many :expenses, ReactiveDagDashboard.FixtureGraph.Expenses do
        source_attribute(:key)
        destination_attribute(:category)
      end
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key, :spend_count])
    end

    reactive do
      id(:expense_tally)
      depends_on([:expenses])
      # declared, and inert: one aggregate means the row is the key plus this
      # column, so there is nothing else to exclude
      compare([:spend_count])

      aggregate(over: :expenses, count: :spend_count)
    end
  end

  defmodule ExpenseScan do
    @behaviour ReactiveDag.Source

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def polls, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def id, do: :expense_scan
    @impl true
    def origin, do: %{label: "Finance export"}
    @impl true
    def poll(opts) do
      if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &[opts | &1])

      # Progress from INSIDE the poll, as a real crawler does. Without this the
      # only test coverage was hand-fired telemetry, which cannot catch a break
      # in the path a scan click actually takes.
      for n <- 1..3 do
        ReactiveDag.Source.progress(n, 3, cell: "expenses", label: "documents")
      end

      # a deep pass reaches an upstream the cheap one never touches, and that
      # upstream is down — the shape a real crawler hits on a full crawl
      unreachable = if opts[:recent] == false, do: [{"archive", :timeout}], else: []

      # a cheap pass sees the rows it always sees; the deep pass reaches an
      # archive that is down and therefore reports nothing new
      changed = if unreachable == [], do: ["e1"], else: []

      # a scanner that reconciles through the library passes its detail back, so
      # the page can say WHAT changed rather than only how many
      detail =
        if changed == [],
          do: %{created: [], updated: [], revived: [], retired: []},
          else: %{created: ["e1"], updated: [], revived: [], retired: []}

      {:ok, %{changed: changed, unreachable: unreachable, detail: detail}}
    end
  end

  # A source feeding TWO leaves — one crawl of one upstream whose rows land in
  # two places. `refresh/3` marks both from a single poll, and the page has to
  # say so: reporting only the cell whose button was pressed would hide half of
  # what the scan just did.
  defmodule Minutes do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key])
    end

    reactive do
      id(:minutes)

      # a projection of the council crawl, not a scanner of its own. `{:skip,
      # key}` declines a document of the other kind — returning nothing would
      # retire it and churn on every poll.
      reduce(
        over: :council_portal,
        group_by: :key,
        expand: fn key, rows ->
          case Enum.filter(rows, &(&1.kind == "minutes")) do
            [] -> [{:skip, key}]
            [_ | _] -> [%{key: key}]
          end
        end
      )
    end
  end

  defmodule Resolutions do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key])
    end

    reactive do
      id(:resolutions)

      reduce(
        over: :council_portal,
        group_by: :key,
        expand: fn key, rows ->
          case Enum.filter(rows, &(&1.kind == "resolution")) do
            [] -> [{:skip, key}]
            [_ | _] -> [%{key: key}]
          end
        end
      )
    end
  end

  # a leaf whose keys arrive some OTHER way — a manual import, a webhook. It has
  # no scanner, and must not be grouped under one.
  defmodule Unscanned do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key])
    end

    reactive do
      id(:unscanned)
      leaf?(true)
    end
  end

  # ONE crawl of the council portal. Its rows land here; `minutes` and
  # `resolutions` are ordinary consumers projecting their own kind out of it.
  # Before the source became a node, both leaves declared `scan CouncilScan` and
  # the module declared `leaf_cells/1` back.
  defmodule CouncilPortal do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [ReactiveDag.Node]

    ets do
    end

    attributes do
      attribute(:key, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:kind, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy])
      create(:upsert, upsert?: true, accept: [:key, :kind])
    end

    reactive do
      id(:council_portal)
      leaf?(true)
      poll(ReactiveDagDashboard.FixtureGraph.CouncilScan)
    end
  end

  defmodule CouncilScan do
    @behaviour ReactiveDag.Source

    @impl true
    def id, do: :council_scan
    @impl true
    def origin, do: %{label: "Council portal"}
    @impl true
    def poll(_opts) do
      # one poll, one cell — what each document IS is a column on the row, and
      # the consumers project on it
      {:ok, %{changed: ["m1", "r1", "r2"]}}
    end
  end

  @doc "The plan, as the router's `:plan` MFA would return it."
  def plan, do: ReactiveDag.Node.graph(resources())

  @doc """
  One TENANT'S plan — the shape a host supplies when the dashboard names
  `tenants:`. The dashboard appends the chosen tenant to the declared args, so
  the same `{FixtureGraph, :plan, []}` reaches `plan/0` or `plan/1`.
  """
  def plan(tenant), do: ReactiveDag.Node.graph(resources(), tenant: tenant)

  @doc "The tenants, as a host's `:tenants` MFA would return them."
  def tenants, do: [{"borough", "Borough of Test"}, {"village", "Village of Test"}]

  defp resources,
    do: [
      Expenses,
      CategoryHealth,
      SpendRollup,
      AllVerdicts,
      ExpenseNotes,
      CouncilPortal,
      Minutes,
      Resolutions,
      Unscanned,
      VerdictAudit,
      Published
    ]

  @doc """
  A SEPARATE plan for the change-basis tests — `expenses` plus the nodes that
  declare a `compare`.

  Its own plan rather than more nodes in `plan/0` on the fixture's own standing
  advice: the shared graph's shape is asserted by the tree and layout tests
  (path counts, level counts, edge counts), and growing the part under test
  should not renumber the rest.
  """
  def compare_plan,
    do: ReactiveDag.Node.graph([Expenses, ExpenseProvenance, ExpenseTally, Watched])

  # recompute/2 returns {:ok, changed} or {:ok, changed, meta} depending on the
  # node shape; normalise so the seed does not care which.
  defp maybe_meta({:ok, changed}), do: {:ok, changed, %{}}
  defp maybe_meta({:ok, changed, meta}), do: {:ok, changed, meta}

  @doc "Seed every cell so the page has real rows to report."
  def seed do
    for r <- [
          Expenses,
          CategoryHealth,
          SpendRollup,
          AllVerdicts,
          ExpenseNotes,
          CouncilPortal,
          Minutes,
          Resolutions,
          Unscanned,
          VerdictAudit
        ],
        row <- Ash.read!(r),
        do: Ash.destroy!(row)

    for {k, cat, amt} <- [{"e1", "travel", 500.0}, {"e2", "meals", 40.0}] do
      Expenses
      |> Ash.Changeset.for_create(:upsert, %{
        key: k,
        category: cat,
        amount: amt,
        fiscal_year: if(k == "e1", do: "FY25", else: "FY24")
      })
      |> Ash.create!()
    end

    for k <- ["u1"],
        do: Unscanned |> Ash.Changeset.for_create(:upsert, %{key: k}) |> Ash.create!()

    # seed the SOURCE; `minutes` and `resolutions` derive from it
    for {k, kind} <- [{"m1", "minutes"}, {"r1", "resolution"}, {"r2", "resolution"}] do
      CouncilPortal |> Ash.Changeset.for_create(:upsert, %{key: k, kind: kind}) |> Ash.create!()
    end

    p = plan()

    for id <- [
          "minutes",
          "resolutions",
          "category_health",
          "spend_rollup",
          "all_verdicts",
          "expense_notes",
          "verdict_audit"
        ] do
      {:ok, _, _} = maybe_meta(ReactiveDag.Node.Recompute.recompute(p.cells[id], ["*"]))
    end

    :ok
  end
end
