# Differential oracle against Saxon-HE running each schematron's reference XSLT:
# deterministic mutants of conforming invoices, with the Saxon verdicts frozen
# per pair in `test/fixtures/oracle/`. Replays without Java; refresh with
# `MIX_ENV=test mix run scripts/refresh_oracle.exs`.
#
# One test module per pair so the pairs run concurrently.
for pair <- ExSchematron.OracleSuite.pairs() do
  defmodule Module.concat(ExSchematron.OracleTest, Macro.camelize(Atom.to_string(pair.key))) do
    use ExUnit.Case, async: true

    alias ExSchematron.FrozenCorpus
    alias ExSchematron.OracleSuite

    @pair pair

    @tag timeout: 300_000
    test "#{pair.key}: every mutant gets exactly the Saxon verdict" do
      pair = @pair
      module = OracleSuite.validator(pair)
      frozen = FrozenCorpus.load!(OracleSuite.manifest_path(pair))
      authored_ids = OracleSuite.authored_ids(pair)

      observed =
        FrozenCorpus.run_all(OracleSuite.mutants(pair), fn _name, xml ->
          OracleSuite.observed_verdict(module, xml, authored_ids)
        end)

      assert FrozenCorpus.drift(frozen, observed) == %{not_run: [], not_frozen: [], mismatches: []}
    end
  end
end

defmodule ExSchematron.OracleTest.CompileOnly do
  use ExUnit.Case, async: true

  alias ExSchematron.OracleSuite

  # The FNFE corpus ships no example document for these, so there is nothing to
  # mutate and no Saxon verdict to freeze. Compiling them still guards the
  # library against a construct it does not support, which is a compile-time
  # raise, and running one document guards the generated code against a runtime
  # error in a rule that never matches.
  for pair <- OracleSuite.compile_only() do
    @pair pair

    test "#{pair.key}: compiles and validates a document its rules do not match" do
      module = OracleSuite.validator(@pair)

      assert module.validate(~S(<?xml version="1.0"?><nothing-here/>)) == []
    end
  end
end
