defmodule ExSchematron.OracleTest do
  @moduledoc """
  Differential oracle against Saxon-HE running the FNFE-compiled XSLT of
  BR-FR-Flux2-CII: 726 deterministic mutants of two conforming invoices, with
  the Saxon verdicts frozen in `test/fixtures/oracle_verdicts.exs`.

  Replays without Java. To refresh the manifest after a schematron update, see
  scripts/gen_mutants.exs and scripts/diff_oracle.exs.
  """

  use ExUnit.Case, async: false

  alias ExSchematron.Mutator

  @fixtures Path.join(__DIR__, "../fixtures")
  @invoices [
    "UC1_F202500003_00-INV_20250701_CII_EN16931.xml",
    "UC10_F202600004_MULTI-VENDEUR_CII_Commentee_EXTENDED.xml"
  ]

  setup_all do
    module = ExSchematron.Generated.BrFrFlux2Cii

    unless Code.ensure_loaded?(module) do
      [{^module, _binary} | _rest] = Code.compile_file(Path.join(__DIR__, "../../gen/br_fr_flux2_cii.ex"))
    end

    {verdicts, _bindings} = Code.eval_file(Path.join(@fixtures, "oracle_verdicts.exs"))
    {:ok, validator: module, verdicts: verdicts}
  end

  test "the conforming invoices raise no violation", %{validator: module} do
    for invoice <- @invoices do
      assert module.validate(File.read!(Path.join([@fixtures, "invoices", invoice]))) == [],
             "expected no violation for #{invoice}"
    end
  end

  @tag timeout: 300_000
  test "every mutant gets exactly the Saxon verdict", %{validator: module, verdicts: verdicts} do
    mutants =
      Enum.flat_map(@invoices, fn invoice ->
        source = File.read!(Path.join([@fixtures, "invoices", invoice]))
        Mutator.mutants(source, Path.basename(invoice, ".xml"))
      end)

    assert length(mutants) == map_size(verdicts)

    mismatches =
      mutants
      |> Task.async_stream(
        fn {name, xml} ->
          expected = Map.fetch!(verdicts, name)
          violations = module.validate(xml)

          errors = for violation <- violations, violation.type == :error, do: violation.message
          actual = for violation <- violations, violation.type != :error, do: violation.rule
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
