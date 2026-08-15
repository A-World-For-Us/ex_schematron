# Regenerates the frozen outcome manifest of the ISO Schematron conformance
# corpus (git submodule `test/fixtures/conformance`). Runs in the test
# environment, where the conformance support module is compiled:
#
#   MIX_ENV=test mix run scripts/refresh_conformance.exs
#
# Prints the conformance score and the testcases we do not pass, so a refresh
# doubles as a coverage report.

alias ExSchematron.ConformanceSuite

ConformanceSuite.available?() ||
  raise "conformance corpus missing; run `git submodule update --init test/fixtures/conformance`"

results =
  Enum.map(ConformanceSuite.testcases(), fn testcase ->
    outcomes = ConformanceSuite.run(testcase)
    {testcase, outcomes, ConformanceSuite.conforms?(testcase, outcomes)}
  end)

{passing, failing} = Enum.split_with(results, fn {_testcase, _outcomes, conforms?} -> conforms? end)

# Emitted key by key rather than by inspecting a map: past 32 entries a map no
# longer inspects in key order, and an unstable manifest is unreviewable.
entries =
  results
  |> Enum.sort_by(fn {testcase, _outcomes, _conforms?} -> testcase.key end)
  |> Enum.map_join("\n", fn {testcase, outcomes, conforms?} ->
    ~s(  # expect #{testcase.expect}#{if conforms?, do: "", else: " -- NOT CONFORMING"}\n) <>
      ~s(  #{inspect(testcase.key)} => #{inspect(outcomes, limit: :infinity, printable_limit: :infinity)},)
  end)

manifest = """
# Frozen outcomes of the ISO Schematron conformance corpus, one entry per
# testcase file, one outcome per schema of that testcase. Replayed by
# `test/ex_schematron/conformance_test.exs`; regenerate with
# `MIX_ENV=test mix run scripts/refresh_conformance.exs`.
#
# Conforming: #{length(passing)}/#{length(results)}.
%{
#{entries}
}
"""

formatter_opts = ".formatter.exs" |> Code.eval_file() |> elem(0) |> Keyword.take([:line_length])
File.write!(ConformanceSuite.manifest_path(), [Code.format_string!(manifest, formatter_opts), "\n"])

IO.puts("#{length(passing)}/#{length(results)} testcases conform\n")

failing
|> Enum.sort_by(fn {testcase, _outcomes, _conforms?} -> testcase.key end)
|> Enum.each(fn {testcase, outcomes, _conforms?} ->
  IO.puts("#{testcase.key} (expect #{testcase.expect}): #{inspect(outcomes)}")
end)
