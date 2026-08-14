# Regenerates the frozen Saxon verdict manifests for every oracle pair.
# Requires Java, the Saxon jars in tools/, and the FNFE corpus. Runs in the
# test environment, where the oracle support modules are compiled:
#
#   RFE_SPECS=.../FNFE_SCHEMATRONS_FR_CTC_V1.3.1_2026_04_30 MIX_ENV=test mix run scripts/refresh_oracle.exs [pair_key ...]
#
# Also diffs our compiled modules against the fresh verdicts and exits non-zero
# on any divergence, so a refresh doubles as a full differential run.

alias ExSchematron.OracleSuite
alias ExSchematron.Xml

corpus = System.get_env("RFE_SPECS") || raise "set RFE_SPECS to the FNFE schematron corpus directory"

classpath =
  ["Saxon-HE-12.10.jar", "xmlresolver-5.2.2.jar", "xmlresolver-5.2.2-data.jar"]
  |> Enum.map(fn jar ->
    path = Path.join("tools", jar)
    File.exists?(path) || raise "missing #{path}; download it from Maven Central"
    path
  end)
  |> Enum.join(":")

svrl_ns = "http://purl.oclc.org/dsdl/svrl"

svrl_failed_keys = fn svrl_path, authored_ids ->
  doc = svrl_path |> File.read!() |> Xml.parse!()

  for {_id, node} <- doc.nodes,
      node.kind == :element,
      node.name == {svrl_ns, "failed-assert"} or node.name == {svrl_ns, "successful-report"} do
    attrs = Map.new(Xml.attributes(doc, node.id), fn attr -> {elem(attr.name, 1), attr.value} end)
    ExSchematron.OracleSuite.verdict_key(attrs["id"], Map.fetch!(attrs, "test"), authored_ids)
  end
end

selected = System.argv() |> Enum.map(&String.to_atom/1) |> MapSet.new()
pairs = Enum.filter(OracleSuite.pairs(), fn pair -> MapSet.size(selected) == 0 or pair.key in selected end)

failures =
  Enum.flat_map(pairs, fn pair ->
    work_dir = Path.join(System.tmp_dir!(), "ex_schematron_oracle_#{pair.key}")
    mutants_dir = Path.join(work_dir, "mutants")
    svrl_dir = Path.join(work_dir, "svrl")
    File.rm_rf!(work_dir)
    File.mkdir_p!(mutants_dir)
    File.mkdir_p!(svrl_dir)

    mutants = OracleSuite.mutants(pair)
    for {name, xml} <- mutants, do: File.write!(Path.join(mutants_dir, name <> ".xml"), xml)

    xsl = Path.join(corpus, pair.xsl)
    IO.puts("#{pair.key}: #{length(mutants)} documents through Saxon (#{Path.basename(xsl)})...")

    {output, status} =
      System.cmd(
        "java",
        ["-cp", classpath, "net.sf.saxon.Transform", "-s:#{mutants_dir}", "-o:#{svrl_dir}", "-xsl:#{xsl}"],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("Saxon failed for #{pair.key}: #{String.slice(output, 0, 500)}")

    authored_ids = OracleSuite.authored_ids(pair)

    verdicts =
      Map.new(mutants, fn {name, _xml} ->
        {name, svrl_dir |> Path.join(name <> ".xml") |> svrl_failed_keys.(authored_ids) |> Enum.sort()}
      end)

    manifest = OracleSuite.manifest_path(pair)
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(manifest, inspect(verdicts, limit: :infinity, printable_limit: :infinity, pretty: true) <> "\n")

    module = ExSchematron.compile_file!(OracleSuite.sch_path(pair), Module.concat(OracleRefresh, pair.key))

    pair_failures =
      mutants
      |> Task.async_stream(
        fn {name, xml} ->
          violations = module.validate(xml)
          errors = for violation <- violations, violation.type == :error, do: violation.message

          actual =
            for violation <- violations, violation.type != :error do
              OracleSuite.verdict_key(violation.rule, violation.test, authored_ids)
            end

          actual = Enum.sort(actual)
          expected = Map.fetch!(verdicts, name)

          if actual == expected and errors == [] do
            []
          else
            [%{pair: pair.key, mutant: name, missing: expected -- actual, extra: actual -- expected, errors: errors}]
          end
        end,
        ordered: false,
        timeout: 120_000
      )
      |> Enum.flat_map(fn {:ok, result} -> result end)

    total_verdicts = verdicts |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    IO.puts("#{pair.key}: #{map_size(verdicts)} verdicts (#{total_verdicts} failed-asserts), #{length(pair_failures)} mismatches")
    pair_failures
  end)

for failure <- Enum.take(failures, 30) do
  IO.puts("\n#{failure.pair} / #{failure.mutant}")
  if failure.missing != [], do: IO.puts("  manquants (FAUX NÉGATIFS): #{inspect(Enum.take(failure.missing, 10))}")
  if failure.extra != [], do: IO.puts("  en trop (faux positifs): #{inspect(Enum.take(failure.extra, 10))}")
  if failure.errors != [], do: IO.puts("  erreurs runtime: #{inspect(Enum.take(failure.errors, 3))}")
end

IO.puts("\ntotal mismatches: #{length(failures)}")
if failures != [], do: System.halt(1)
