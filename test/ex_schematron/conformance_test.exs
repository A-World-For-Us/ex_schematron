# ISO Schematron conformance corpus (git submodule `test/fixtures/conformance`,
# github.com/Schematron/schematron-conformance): each testcase carries its own
# documents, schema and expected outcome. The library does not pass the whole
# corpus yet, so the outcomes are frozen in `test/fixtures/conformance_manifest.exs`
# and replayed here -- a testcase that starts or stops conforming fails the run.
#
# Tagged `:conformance`; run it alone with `mix test.conformance`. Refresh the
# manifest with `MIX_ENV=test mix run scripts/refresh_conformance.exs`.
defmodule ExSchematron.ConformanceTest do
  use ExUnit.Case, async: true

  alias ExSchematron.ConformanceSuite

  @moduletag :conformance

  if ConformanceSuite.available?() do
    manifest = ExSchematron.FrozenCorpus.load!(ConformanceSuite.manifest_path())
    testcases = ConformanceSuite.testcases()

    @keys Enum.map(testcases, & &1.key)
    @manifest_keys Map.keys(manifest)

    test "the manifest covers exactly the corpus" do
      assert Enum.sort(@manifest_keys) == Enum.sort(@keys)
    end

    for testcase <- testcases, Map.has_key?(manifest, testcase.key) do
      @testcase testcase
      @expected Map.fetch!(manifest, testcase.key)

      test "#{testcase.key}: #{testcase.label}" do
        outcomes = ConformanceSuite.run(@testcase)

        assert outcomes == @expected,
               """
               conformance outcome changed for #{@testcase.key} (expect #{@testcase.expect})

                 frozen:   #{inspect(@expected)}
                 observed: #{inspect(outcomes)}

               Refresh with `MIX_ENV=test mix run scripts/refresh_conformance.exs`.
               """
      end
    end
  else
    @tag :skip
    test "conformance corpus is checked out" do
      flunk("run `git submodule update --init test/fixtures/conformance`")
    end
  end
end
