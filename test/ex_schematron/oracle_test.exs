# Differential oracle against Saxon-HE running each schematron's reference XSLT:
# deterministic mutants of conforming invoices, with the Saxon verdicts frozen
# per pair in `test/fixtures/oracle/`. Replays without Java; refresh with
# `RFE_SPECS=... MIX_ENV=test mix run scripts/refresh_oracle.exs`.
#
# One test module per pair so the pairs run concurrently.
for pair <- ExSchematron.OracleSuite.pairs() do
  defmodule Module.concat(ExSchematron.OracleTest, Macro.camelize(Atom.to_string(pair.key))) do
    use ExUnit.Case, async: true

    alias ExSchematron.OracleSuite

    @pair pair

    @tag timeout: 300_000
    test "#{pair.key}: every mutant gets exactly the Saxon verdict" do
      pair = @pair
      module = OracleSuite.validator(pair)
      {verdicts, _bindings} = Code.eval_file(OracleSuite.manifest_path(pair))
      authored_ids = OracleSuite.authored_ids(pair)

      mutants = OracleSuite.mutants(pair)
      assert length(mutants) == map_size(verdicts)

      mismatches =
        mutants
        |> Task.async_stream(
          fn {name, xml} ->
            expected = Map.fetch!(verdicts, name)
            violations = module.validate(xml)

            errors = for violation <- violations, violation.type == :error, do: violation.message

            actual =
              for violation <- violations, violation.type != :error do
                OracleSuite.verdict_key(violation.rule, violation.test, authored_ids)
              end

            actual = Enum.sort(actual)

            if actual == expected and errors == [] do
              []
            else
              [{name, %{missing: expected -- actual, extra: actual -- expected, errors: errors}}]
            end
          end,
          ordered: false,
          timeout: 120_000
        )
        |> Enum.flat_map(fn {:ok, result} -> result end)

      assert mismatches == []
    end
  end
end
