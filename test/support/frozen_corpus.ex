defmodule ExSchematron.FrozenCorpus do
  @moduledoc """
  The shared machinery of a frozen-corpus regression suite: a corpus of cases
  is run once, the outcomes are frozen in a manifest, and every later run is
  compared against it. The oracle suite (Saxon verdicts per mutant) and the
  conformance suite (ISO corpus outcomes per testcase) are the two adapters.

  Owns the parts each suite used to reimplement:

    * `write!/3` — manifest serialization, emitted key by key in sorted order
      (past 32 entries a map no longer inspects in key order, and an unstable
      manifest is unreviewable) and formatted with the project formatter, so
      the same entries always produce the same bytes;
    * `load!/1` — the inverse;
    * `run_all/2` — the concurrent case runner;
    * `drift/2` — frozen-versus-observed comparison, covering the key sets
      (a case that appears or disappears is drift too, not just a changed
      outcome).
  """

  @doc "Loads a manifest written by `write!/3`: `%{key => frozen outcome}`."
  @spec load!(Path.t()) :: map()
  def load!(path), do: path |> Code.eval_file() |> elem(0)

  @doc """
  Writes `entries` (`{key, outcome}` pairs) as a manifest at `path`.

  `:header` (required) is a plain-text preamble emitted as a comment block.
  `:comment` is an optional `fn key, outcome -> text | nil end` emitting a
  comment line above an entry.
  """
  @spec write!(Path.t(), Enumerable.t(), keyword()) :: :ok
  def write!(path, entries, opts) do
    header = Keyword.fetch!(opts, :header)
    comment = Keyword.get(opts, :comment, fn _key, _outcome -> nil end)

    body =
      entries
      |> Enum.sort_by(fn {key, _outcome} -> key end)
      |> Enum.map_join("\n", fn {key, outcome} ->
        prefix =
          case comment.(key, outcome) do
            nil -> ""
            text -> "  # #{text}\n"
          end

        prefix <> "  #{inspect(key)} => #{inspect(outcome, limit: :infinity, printable_limit: :infinity)},"
      end)

    source = "#{comment_block(header)}\n%{\n#{body}\n}\n"
    formatter_opts = ".formatter.exs" |> Code.eval_file() |> elem(0) |> Keyword.take([:line_length])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Code.format_string!(source, formatter_opts), "\n"])
  end

  @doc "Runs `fun.(key, data)` over `{key, data}` cases concurrently: `%{key => outcome}`."
  @spec run_all(Enumerable.t(), (term(), term() -> term())) :: map()
  def run_all(cases, fun) do
    cases
    |> Task.async_stream(fn {key, data} -> {key, fun.(key, data)} end, ordered: false, timeout: 120_000)
    |> Map.new(fn {:ok, entry} -> entry end)
  end

  @doc """
  Drift of an observed run against the frozen manifest.

    * `not_run` — frozen keys the run did not produce (a case disappeared),
    * `not_frozen` — observed keys the manifest does not cover (a new case),
    * `mismatches` — cases whose outcome changed. When both outcomes are
      lists, the mismatch carries `missing`/`extra` element diffs; otherwise
      the raw `expected`/`observed` terms.
  """
  @spec drift(map(), map()) :: %{not_run: list(), not_frozen: list(), mismatches: [map()]}
  def drift(frozen, observed) do
    mismatches =
      for {key, expected} <- Enum.sort(frozen),
          {:ok, outcome} <- [Map.fetch(observed, key)],
          outcome != expected,
          do: mismatch(key, expected, outcome)

    %{
      not_run: Enum.sort(Map.keys(frozen) -- Map.keys(observed)),
      not_frozen: Enum.sort(Map.keys(observed) -- Map.keys(frozen)),
      mismatches: mismatches
    }
  end

  @doc "True when a drift report is empty: the run reproduced the manifest exactly."
  @spec clean?(map()) :: boolean()
  def clean?(drift), do: drift == %{not_run: [], not_frozen: [], mismatches: []}

  defp mismatch(key, expected, observed) when is_list(expected) and is_list(observed) do
    %{key: key, missing: expected -- observed, extra: observed -- expected}
  end

  defp mismatch(key, expected, observed), do: %{key: key, expected: expected, observed: observed}

  defp comment_block(header) do
    header
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> "#"
      line -> "# " <> line
    end)
  end
end
