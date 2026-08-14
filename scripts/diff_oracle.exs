# Differential oracle: compares our compiled module's verdicts with Saxon SVRL
# references, mutant by mutant.
#
#   mix run scripts/diff_oracle.exs SCHEMA.sch MUTANTS_DIR SVRL_DIR

alias ExSchematron.Xml

[sch_path, mutants_dir, svrl_dir] = System.argv()
module = ExSchematron.compile!(File.read!(sch_path), OracleDiffValidator)

svrl_ns = "http://purl.oclc.org/dsdl/svrl"

svrl_failed_ids = fn svrl_path ->
  doc = svrl_path |> File.read!() |> Xml.parse!()

  for {_id, node} <- doc.nodes,
      node.kind == :element,
      node.name == {svrl_ns, "failed-assert"} or node.name == {svrl_ns, "successful-report"},
      attr <- Xml.attributes(doc, node.id),
      attr.name == {nil, "id"},
      do: attr.value
end

mutants = mutants_dir |> Path.join("*.xml") |> Path.wildcard() |> Enum.sort()

{mismatches, saxon_missing, checked} =
  Enum.reduce(mutants, {[], 0, 0}, fn mutant_path, {mismatches, saxon_missing, checked} ->
    svrl_path = Path.join(svrl_dir, Path.basename(mutant_path, ".xml") <> ".xml")

    if File.exists?(svrl_path) do
      expected = mutant_path |> Path.basename(".xml") |> then(fn _ -> svrl_failed_ids.(svrl_path) end) |> Enum.sort()

      violations = module.validate(File.read!(mutant_path))
      errors = for violation <- violations, violation.type == :error, do: violation
      actual = for violation <- violations, violation.type != :error, do: violation.rule
      actual = Enum.sort(actual)

      if expected == actual and errors == [] do
        {mismatches, saxon_missing, checked + 1}
      else
        detail = %{
          mutant: Path.basename(mutant_path),
          missing: expected -- actual,
          extra: actual -- expected,
          errors: Enum.map(errors, & &1.message)
        }

        {[detail | mismatches], saxon_missing, checked + 1}
      end
    else
      # Saxon aborted on this mutant (dynamic error): no reference to compare.
      {mismatches, saxon_missing + 1, checked}
    end
  end)

IO.puts("#{checked} mutants compared, #{length(mismatches)} mismatches, #{saxon_missing} without Saxon reference")

mismatches
|> Enum.reverse()
|> Enum.take(30)
|> Enum.each(fn detail ->
  IO.puts("\n#{detail.mutant}")
  if detail.missing != [], do: IO.puts("  manquants (Saxon oui, nous non — FAUX NÉGATIFS): #{inspect(detail.missing)}")
  if detail.extra != [], do: IO.puts("  en trop (nous oui, Saxon non — faux positifs): #{inspect(detail.extra)}")
  if detail.errors != [], do: IO.puts("  erreurs runtime: #{inspect(Enum.take(detail.errors, 3))}")
end)

if mismatches != [], do: System.halt(1)
