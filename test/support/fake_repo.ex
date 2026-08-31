defmodule ReactiveDagDashboard.FakeRepo do
  @moduledoc """
  An in-memory stand-in for the suspension table — this suite has no Postgres.

  Only the queries `ReactiveDag.Suspension` and `ReactiveDag.Lock` actually
  issue are implemented, which is enough to drive a real `Cascade.run/3`: the
  cascade's whole interaction with the outside world is *record where I stopped*
  and *run this in a transaction*.

  ## What this replaces

  A fake dirty frontier, and it is much smaller than that was. The frontier fake
  had to model mark → claim → count over a seven-column INSERT with an
  `ON CONFLICT` merge; suspensions are append-only, so there is nothing to merge
  and no claim to model. Half of what that file existed for is a part of the
  engine that no longer exists.

  ## Why not the library's own fake

  `ReactiveDag.Test.FakeSuspensionRepo` is exactly this, and is maintained beside
  the SQL it mirrors. It lives in the library's `test/support`, which Hex does
  not ship, so a dependent cannot reach it. This is therefore a copy — and being
  a copy is what makes it drift. It has drifted before: the frontier's INSERT
  grew a column and every test here failed on a clause miss three releases later.

  ## Transactions are real here

  `transaction/2` and `rollback/1` are implemented rather than absent, and that
  matters more than it sounds. `Suspension.transaction/1` only wraps when the
  repo exports `transaction/2` — so a fake without it silently takes the
  no-transaction path, and a test asserting anything about a cascade's atomicity
  would pass for the wrong reason. `savepoint/1` is the same: without a real
  `rollback/1` a failing cell would not be isolated, and a test checking that a
  contained failure stays contained would be checking nothing.
  """

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc false
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc "Every suspension recorded, oldest first."
  def recorded, do: Agent.get(__MODULE__, &Enum.reverse/1)

  @doc "The distinct resources with work suspended, sorted."
  def waiting, do: recorded() |> Enum.map(& &1.waiting) |> Enum.uniq() |> Enum.sort()

  @doc "Suspensions as `{waiting, resource, row_uuid}`, sorted — the usual assertion."
  def points do
    recorded()
    |> Enum.map(&{&1.waiting, &1.resource, &1.row_uuid})
    |> Enum.sort()
  end

  @doc "Drop everything, for a test wanting a known-empty state mid-run."
  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

  # ---- the repo surface the library calls ----

  def query!(sql, params \\ [])

  # `record/3`. Seven parameters, in the order the SQL names its columns.
  def query!("INSERT INTO " <> _, [id, tenant, waiting, resource, row_uuid, version_id, reason]) do
    Agent.update(
      __MODULE__,
      &[
        %{
          id: id,
          tenant: tenant,
          waiting: waiting,
          resource: resource,
          row_uuid: row_uuid,
          version_id: version_id,
          reason: reason
        }
        | &1
      ]
    )

    %{rows: [], num_rows: 1}
  end

  # `at/1` — every suspension at one point, oldest first.
  def query!("SELECT id, version_id, reason" <> _, [tenant, waiting, resource, row_uuid]) do
    rows =
      recorded()
      |> Enum.filter(
        &(&1.tenant == tenant and &1.waiting == waiting and &1.resource == resource and
            &1.row_uuid == row_uuid)
      )
      |> Enum.map(&[&1.id, &1.version_id, &1.reason])

    %{rows: rows, num_rows: length(rows)}
  end

  # `points/1` — one entry per (point, reason), with a count and the oldest.
  # This is what `Insights.pending/1` reads, so the dashboard's "waiting" banner
  # is driven by real suspensions rather than by a stub.
  def query!("SELECT tenant, waiting, resource" <> _, [tenant]) do
    rows =
      recorded()
      |> Enum.filter(&(&1.tenant == tenant))
      |> Enum.group_by(&{&1.tenant, &1.waiting, &1.resource, &1.row_uuid, &1.reason})
      |> Enum.map(fn {{t, w, r, u, reason}, group} ->
        [t, w, r, u, reason, length(group), DateTime.utc_now()]
      end)

    %{rows: rows, num_rows: length(rows)}
  end

  # `pending?/1`
  def query!("SELECT COUNT" <> _, [tenant]) do
    n = Enum.count(recorded(), &(&1.tenant == tenant))
    %{rows: [[n]], num_rows: 1}
  end

  # `discharge/1` — BY ID, never by point. A suspension written while a job was
  # running is not in the id list and must survive; this models that faithfully,
  # because it is the property the whole append-only design rests on.
  def query!("DELETE FROM " <> _, [ids]) when is_list(ids) do
    removed =
      Agent.get_and_update(__MODULE__, fn all ->
        {gone, kept} = Enum.split_with(all, &(&1.id in ids))
        {length(gone), kept}
      end)

    %{rows: [], num_rows: removed}
  end

  # The advisory lock `ReactiveDag.Lock` takes around a sweep — always granted,
  # since a single-process fake never contends. This is the one thing that
  # survived the frontier, and only because it guards HTTP fetching rather than
  # propagation.
  def query!("SELECT pg_try_advisory_lock" <> _, _), do: %{rows: [[true]], num_rows: 1}
  def query!("SELECT pg_advisory_unlock" <> _, _), do: %{rows: [[true]], num_rows: 1}

  # ---- transactions ----

  def transaction(fun, _opts \\ []) do
    {:ok, fun.()}
  catch
    :throw, {:rd_rollback, reason} -> {:error, reason}
  end

  def rollback(reason), do: throw({:rd_rollback, reason})
end
