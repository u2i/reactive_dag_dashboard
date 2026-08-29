defmodule ReactiveDagDashboard.FakeRepo do
  @moduledoc """
  An in-memory dirty frontier — this suite has no Postgres.

  Only the queries `ReactiveDag.Frontier` actually issues are implemented, which
  is enough to drive a real `Drain.run/2`: the drain's whole interaction with the
  outside world is mark → claim → count.
  """

  def start_link, do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  @doc "The `{cell, key}` pairs currently marked dirty, for the default tenant."
  def marks do
    Agent.get(__MODULE__, & &1)
    |> Enum.filter(fn {t, _c, _k} -> t == "*" end)
    |> Enum.map(fn {_t, c, k} -> {c, k} end)
    |> Enum.sort()
  end

  @doc "The `{cell, key}` pairs marked for `tenant`."
  def marks(tenant) do
    Agent.get(__MODULE__, & &1)
    |> Enum.filter(fn {t, _c, _k} -> t == tenant end)
    |> Enum.map(fn {_t, c, k} -> {c, k} end)
    |> Enum.sort()
  end

  # Rows are `{tenant, cell, key}` — the library's frontier is keyed by
  # (tenant, cell_id, key), and a fake that dropped the tenant would let a
  # tenant-scoping bug pass every test here.
  # SEVEN columns: `(cell_id, tenant, key, reason, enqueued_at, awaiting_approval,
  # version_id)`. The mark carries a REFERENCE to the change (`version_id`) rather
  # than an inlined diff, and `awaiting_approval` gates a change waiting on a person.
  #
  # This fake had six and was three releases behind, so every drain here failed on a
  # clause miss the moment the library moved. It is a copy of the wire format, which
  # is what makes it drift — the library keeps its own shared fake, but in
  # `test/support`, which Hex does not ship.
  def query!("INSERT INTO " <> _, params) do
    params
    |> Enum.chunk_every(7)
    |> Enum.each(fn [cell, tenant, key, _reason, _at, _held, _version_id] ->
      Agent.update(__MODULE__, &MapSet.put(&1, {tenant, cell, key}))
    end)

    %{rows: []}
  end

  def query!("SELECT DISTINCT cell_id" <> _, [tenant]) do
    ids =
      Agent.get(__MODULE__, & &1)
      |> Enum.filter(fn {t, _c, _k} -> t == tenant end)
      |> Enum.map(fn {_t, c, _k} -> c end)
      |> Enum.uniq()

    %{rows: Enum.map(ids, &[&1])}
  end

  def query!("DELETE FROM " <> _, [cell, tenant]) do
    claimed =
      Agent.get_and_update(__MODULE__, fn set ->
        {mine, rest} = Enum.split_with(set, fn {t, c, _k} -> t == tenant and c == cell end)
        {mine, MapSet.new(rest)}
      end)

    %{rows: Enum.map(claimed, fn {_t, _c, k} -> [k, nil] end)}
  end

  def query!("SELECT COUNT" <> _, [tenant]) do
    n = Agent.get(__MODULE__, & &1) |> Enum.count(fn {t, _c, _k} -> t == tenant end)
    %{rows: [[n]]}
  end

  # the advisory lock the sweep takes — always granted
  def query!("SELECT pg_try_advisory_lock" <> _, _), do: %{rows: [[true]]}
  def query!("SELECT pg_advisory_unlock" <> _, _), do: %{rows: [[true]]}
end
