defmodule ReactiveDagDashboard.SourceLink do
  @moduledoc """
  What a node's implementation says about itself: a one-line description and a
  link to the code.

  `compute MeetingJoin` names a module and tells you nothing about what it does.
  But the module already explains itself — cascade's `MeetingJoin` opens with
  *"the convergence node: `meeting` = join of the four per-leg datasets by
  meeting_id"*, which is a better description than any UI could invent, and it
  is compiled into the BEAM where `Code.fetch_docs/1` can read it.

  The same call gives the defining line, and `module_info(:compile)[:source]`
  gives the file. So a link to the exact line is derivable; only the repo URL is
  not, because the library cannot know where a host's code lives.

  ## Configuration

      config :reactive_dag_dashboard,
        source_url: "https://github.com/u2i/cascade/blob/main/%{path}#L%{line}"

  `%{path}` is relative to the project root, `%{line}` the module's first line.
  Without it the description still renders — the link is what needs the host's
  help, not the explanation.

  ## Why not derive it from `mix.exs`

  Most projects set `:source_url` for HexDocs already, so this could be
  zero-config. But that URL points at the release tag, and a dashboard renders
  what is DEPLOYED — a link that silently drifts to a different revision is
  worse than no link, because it is only wrong for the reader who follows it.
  """

  @doc """
  A node's implementation, as `%{module:, summary:, url:}` — or `nil` when it
  has none.

  A `compute` or `run` node has a module; a declarative `reduce`/`join` is
  described by its own DSL and needs nothing here.
  """
  @spec describe(struct() | nil) ::
          %{module: module(), summary: String.t() | nil, url: String.t() | nil} | nil
  def describe(nil), do: nil

  def describe(cell) do
    case implementation(cell) do
      nil -> nil
      mod -> %{module: mod, summary: summary(mod), url: url(mod)}
    end
  end

  @doc "The first paragraph of a module's `@moduledoc`, as a single line."
  @spec summary(module()) :: String.t() | nil
  def summary(mod) do
    with {:docs_v1, _anno, _lang, _fmt, %{"en" => doc}, _meta, _docs} <- fetch_docs(mod) do
      doc
      |> String.split("\n\n", parts: 2)
      |> hd()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> nonempty()
    else
      _ -> nil
    end
  end

  @doc "A link to the module's definition, when the host configured a template."
  @spec url(module()) :: String.t() | nil
  def url(mod) do
    with template when is_binary(template) <- config(:source_url),
         {path, line} when not is_nil(path) <- location(mod) do
      template
      |> String.replace("%{path}", path)
      |> String.replace("%{line}", to_string(line))
    else
      _ -> nil
    end
  end

  # ── the module behind a cell ────────────────────────────────────────────────

  # EVERY node has an implementation somewhere; the question is only which
  # module is the most specific thing to open.
  #
  #   * `compute Mod` — the module IS the recompute.
  #   * `poll Mod` — the scanner. For a source that is the crawl itself, which
  #     is usually the most interesting code in the graph.
  #   * anything else — the node's own resource, whose `reactive do` block is
  #     the implementation for a declarative reduce/join.
  #
  # This used to be the first case only, which covered a third of a real graph:
  # in one host, 23 compute nodes had links and 7 sources plus 6 declarative
  # nodes had none. The fixture hid it — its only linked node was a `compute`.
  defp implementation(cell) do
    cond do
      is_atom(cell[:compute]) and not is_nil(cell[:compute]) -> cell[:compute]
      is_atom(cell[:scan]) and not is_nil(cell[:scan]) -> cell[:scan]
      is_atom(cell[:resource]) and not is_nil(cell[:resource]) -> cell[:resource]
      true -> nil
    end
  end

  # Relative to the project root, because that is what a blob URL wants and
  # because an absolute build path is meaningless on anyone else's machine.
  defp location(mod) do
    with true <- Code.ensure_loaded?(mod),
         source when is_list(source) <- mod.module_info(:compile)[:source],
         {:docs_v1, anno, _, _, _, _, _} <- fetch_docs(mod) do
      {relative(to_string(source)), line_of(anno)}
    else
      _ -> {nil, nil}
    end
  end

  defp relative(path) do
    cwd = File.cwd!()

    case String.starts_with?(path, cwd) do
      true -> path |> String.replace_prefix(cwd, "") |> String.trim_leading("/")
      # compiled elsewhere (a release, a different checkout): keep the tail from
      # `lib/`, which is right far more often than the absolute path is
      false -> path |> String.split("/lib/") |> List.last() |> then(&"lib/#{&1}")
    end
  end

  defp line_of(anno) when is_integer(anno), do: anno
  defp line_of({line, _col}), do: line
  defp line_of(_), do: 1

  defp fetch_docs(mod) do
    if Code.ensure_loaded?(mod), do: Code.fetch_docs(mod), else: nil
  rescue
    _ -> nil
  end

  defp nonempty(""), do: nil
  defp nonempty(s), do: s

  defp config(key), do: Application.get_env(:reactive_dag_dashboard, key)
end
