defmodule ReactiveDagDashboard.FakeRepo do
  @moduledoc """
  An in-memory dirty frontier — this suite has no Postgres.

  Only the queries `ReactiveDag.Frontier` actually issues are implemented, which
  is enough to drive a real `Drain.run/2`: the drain's whole interaction with the
  outside world is mark → claim → count.
  """

  def start_link, do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  def query!("INSERT INTO " <> _, params) do
    params
    |> Enum.chunk_every(5)
    |> Enum.each(fn [cell, key, _r, _t, _prior] ->
      Agent.update(__MODULE__, &MapSet.put(&1, {cell, key}))
    end)

    %{rows: []}
  end

  def query!("SELECT DISTINCT cell_id" <> _, _params) do
    ids = Agent.get(__MODULE__, & &1) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    %{rows: Enum.map(ids, &[&1])}
  end

  def query!("DELETE FROM " <> _, [cell]) do
    claimed =
      Agent.get_and_update(__MODULE__, fn set ->
        {mine, rest} = Enum.split_with(set, fn {c, _} -> c == cell end)
        {mine, MapSet.new(rest)}
      end)

    %{rows: Enum.map(claimed, fn {_c, k} -> [k, nil] end)}
  end

  def query!("SELECT COUNT" <> _, _), do: %{rows: [[Agent.get(__MODULE__, &MapSet.size/1)]]}
end
