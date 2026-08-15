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

ConformanceSuite.write_manifest!(results)

IO.puts("#{length(passing)}/#{length(results)} testcases conform\n")

failing
|> Enum.sort_by(fn {testcase, _outcomes, _conforms?} -> testcase.key end)
|> Enum.each(fn {testcase, outcomes, _conforms?} ->
  IO.puts("#{testcase.key} (expect #{testcase.expect}): #{inspect(outcomes)}")
end)
