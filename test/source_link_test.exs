defmodule ReactiveDagDashboard.SourceLinkTest do
  @moduledoc """
  What a node's implementation says about itself.

  `compute MeetingJoin` names a module and explains nothing. The module itself
  explains plenty — it opens with a paragraph saying what the node is for — and
  that text is compiled into the BEAM. So the description is derived rather
  than configured; only the repo URL needs the host's help.
  """
  use ExUnit.Case, async: false

  alias ReactiveDagDashboard.SourceLink

  # A module compiled into `lib`, because a module defined inside a test file
  # carries no docs chunk — `Code.fetch_docs/1` returns `{:error, :chunk_not_found}`
  # for it, and a fixture that cannot have a moduledoc cannot test reading one.
  @documented ReactiveDagDashboard.Tree
  @undocumented ReactiveDagDashboard.SourceLinkTest

  setup do
    prev = Application.get_env(:reactive_dag_dashboard, :source_url)
    on_exit(fn -> Application.put_env(:reactive_dag_dashboard, :source_url, prev) end)
    :ok
  end

  describe "summary/1" do
    test "is the first paragraph, on one line" do
      assert SourceLink.summary(@documented) =~ "The graph as a tree"
    end

    test "a module with no moduledoc has no summary, rather than a placeholder" do
      refute SourceLink.summary(@undocumented)
    end

    test "a module that does not exist is nil, not a crash" do
      refute SourceLink.summary(NoSuchModule)
    end
  end

  describe "url/1" do
    test "fills the host's template with the module's own path and line" do
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")

      url = SourceLink.url(@documented)

      assert url =~ "https://ex.com/lib/reactive_dag_dashboard/tree.ex#L"
    end

    test "no template configured means no link — the summary still renders" do
      Application.put_env(:reactive_dag_dashboard, :source_url, nil)

      refute SourceLink.url(@documented)
      assert SourceLink.summary(@documented)
    end
  end

  describe "describe/1 — what a cell offers" do
    test "a compute node reports its module, summary and link" do
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")

      cell = %ReactiveDag.Cell{id: "x", inputs: ["a"], meta: %{compute: @documented}}

      assert %{module: _, summary: summary, url: url} = SourceLink.describe(cell)
      assert summary =~ "The graph as a tree"
      assert url =~ "https://ex.com/"
    end

    test "a declarative node has no implementation to link to" do
      # a reduce describes itself in the DSL; there is no module to open
      cell = %ReactiveDag.Cell{id: "x", inputs: ["a"], meta: %{reduce: %{}}}

      refute SourceLink.describe(cell)
    end

    test "nil is nil" do
      refute SourceLink.describe(nil)
    end
  end
end
