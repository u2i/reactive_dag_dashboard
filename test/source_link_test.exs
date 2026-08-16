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

  describe "every node shape has an implementation to open" do
    setup do
      Application.put_env(:reactive_dag_dashboard, :source_url, "https://ex.com/%{path}#L%{line}")
      :ok
    end

    test "a SOURCE links to its scanner — usually the most interesting code" do
      # `poll Mod` names the module doing the actual crawling. This used to
      # return nil: only `compute` nodes got a link, which in a real host was a
      # third of the graph.
      cell = %ReactiveDag.Cell{id: "x", inputs: [], meta: %{scan: ReactiveDagDashboard.Tree}}

      assert %{module: ReactiveDagDashboard.Tree, url: url} = SourceLink.describe(cell)
      assert url =~ "tree.ex"
    end

    test "a DECLARATIVE node links to its own resource" do
      # a reduce/join has no module, but its `reactive do` block IS the
      # implementation and lives in the resource file
      cell = %ReactiveDag.Cell{
        id: "x",
        inputs: ["a"],
        meta: %{reduce: %{}, resource: ReactiveDagDashboard.NodeDetail}
      }

      assert %{module: ReactiveDagDashboard.NodeDetail, url: url} = SourceLink.describe(cell)
      assert url =~ "node_detail.ex"
    end

    test "compute wins over both — the most specific thing available" do
      cell = %ReactiveDag.Cell{
        id: "x",
        inputs: ["a"],
        meta: %{
          compute: ReactiveDagDashboard.Tree,
          scan: ReactiveDagDashboard.Actions,
          resource: ReactiveDagDashboard.NodeDetail
        }
      }

      assert %{module: ReactiveDagDashboard.Tree} = SourceLink.describe(cell)
    end

    test "a cell with none of them still reports nothing rather than guessing" do
      assert SourceLink.describe(%ReactiveDag.Cell{id: "x", inputs: [], meta: %{}}) == nil
    end
  end
end
