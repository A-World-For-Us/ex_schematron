defmodule ExSchematron.ConformanceSuite do
  @moduledoc """
  Runs the ISO Schematron conformance corpus vendored as a git submodule in
  `test/fixtures/conformance` (github.com/Schematron/schematron-conformance,
  the suite SchXslt validates against).

  A testcase is one self-contained XML document holding the input document(s),
  one or more schemas, and the expected outcome in `@expect`:

    * `valid`   -- validating the primary document raises nothing and reports nothing
    * `invalid` -- validating reports at least one failed assert / successful report
    * `error`   -- the schema itself is in error and a processor must say so

  Running a testcase materialises its documents and schema into a temp
  directory (secondary documents keep their relative path, so `include` and
  `document()` base-URI fixup are exercised for real), compiles the schema and
  validates the primary document.

  Two adaptations are needed, both recorded rather than hidden:

    * The corpus omits `queryBinding`, i.e. it targets the XSLT 1.0 default
      binding, which this library does not implement. A schema that declares no
      binding is compiled as `xslt2`; a schema that declares one is left alone
      (so the explicit `queryBinding="xslt"` variants surface as errors).
    * `<schemas phase="...">` asks for validation restricted to a phase, which
      `validate/1` has no argument for. Those testcases yield `{:unsupported,
      reason}` instead of a made-up verdict.

  The `<expectations>` of the seven SVRL testcases are XPath assertions over an
  SVRL report; this library returns verdict maps, not SVRL, so only their
  `@expect` is checked.

  Outcomes are frozen in `test/fixtures/conformance_manifest.exs` so the suite
  is a regression check on a library that does not pass the whole corpus yet.
  Refresh with `MIX_ENV=test mix run scripts/refresh_conformance.exs`.
  """

  @corpus Path.join(File.cwd!(), "test/fixtures/conformance")
  @tests_dir Path.join(@corpus, "src/main/resources/tests")
  @manifest Path.join(File.cwd!(), "test/fixtures/conformance_manifest.exs")

  @doc "False when the git submodule has not been checked out."
  def available?, do: File.dir?(@tests_dir)

  def manifest_path, do: @manifest

  @doc "Every testcase of the corpus, ordered by key."
  def testcases do
    @tests_dir
    |> Path.join("**/*.xml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&parse_testcase!/1)
  end

  @doc """
  Validates the primary document once per schema of the testcase, returning one
  outcome per schema: `:valid`, `:invalid`, `{:error, message}` (the library
  refused the schema or blew up on it) or `{:unsupported, reason}` (the harness
  cannot express the testcase).
  """
  def run(testcase) do
    Enum.map(testcase.schemas, &run_schema(testcase, &1))
  end

  @doc "Freezes testcase results (`{testcase, outcomes, conforms?}`) into the manifest, sorted and stable."
  def write_manifest!(results) do
    passing = Enum.count(results, fn {_testcase, _outcomes, conforms?} -> conforms? end)

    notes =
      Map.new(results, fn {testcase, _outcomes, conforms?} ->
        {testcase.key, "expect #{testcase.expect}#{if conforms?, do: "", else: " -- NOT CONFORMING"}"}
      end)

    ExSchematron.FrozenCorpus.write!(
      @manifest,
      Enum.map(results, fn {testcase, outcomes, _conforms?} -> {testcase.key, outcomes} end),
      header: """
      Frozen outcomes of the ISO Schematron conformance corpus, one entry per
      testcase file, one outcome per schema of that testcase. Replayed by
      `test/ex_schematron/conformance_test.exs`; regenerate with
      `MIX_ENV=test mix run scripts/refresh_conformance.exs`.

      Conforming: #{passing}/#{length(results)}.
      """,
      comment: fn key, _outcomes -> Map.fetch!(notes, key) end
    )
  end

  @doc "Whether an outcome list matches what the testcase says a conforming processor must produce."
  def conforms?(testcase, outcomes) do
    Enum.all?(outcomes, &conforming_outcome?(testcase.expect, &1))
  end

  defp conforming_outcome?("valid", outcome), do: outcome == :valid
  defp conforming_outcome?("invalid", outcome), do: outcome == :invalid
  defp conforming_outcome?("error", outcome), do: match?({:error, _message}, outcome)

  defp run_schema(%{phase: phase}, _schema) when phase != nil do
    {:unsupported, "validation restricted to phase #{inspect(phase)}"}
  end

  defp run_schema(testcase, schema) do
    dir = Path.join(System.tmp_dir!(), "ex_schematron-conformance-#{System.unique_integer([:positive])}")

    try do
      schema_path = materialise!(dir, testcase, schema)
      module = Module.concat(ExSchematron.ConformanceValidators, "T#{System.unique_integer([:positive])}")

      # Schemas that are in error make the generated module warn (duplicate
      # variables become duplicate map keys); captured so a run stays readable.
      {violations, _diagnostics} =
        Code.with_diagnostics(fn ->
          ExSchematron.compile_file!(schema_path, module).validate(File.read!(Path.join(dir, testcase.primary)))
        end)

      case violations do
        [] -> :valid
        [_ | _] -> :invalid
      end
    rescue
      exception -> {:error, scrub(Exception.message(exception), dir)}
    catch
      kind, reason -> {:error, scrub("#{kind}: #{inspect(reason)}", dir)}
    after
      File.rm_rf!(dir)
    end
  end

  # Error messages carry the temp directory, which changes every run.
  defp scrub(message, dir), do: String.replace(message, dir <> "/", "")

  defp materialise!(dir, testcase, schema) do
    File.mkdir_p!(dir)

    Enum.each(testcase.documents, fn {filename, content} ->
      path = Path.join(dir, filename)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Saxy.encode!(content))
    end)

    schema_path = Path.join(dir, "schema.sch")
    File.write!(schema_path, schema |> default_query_binding() |> Saxy.encode!())
    schema_path
  end

  defp default_query_binding({name, attributes, children}) do
    if List.keymember?(attributes, "queryBinding", 0) do
      {name, attributes, children}
    else
      {name, [{"queryBinding", "xslt2"} | attributes], children}
    end
  end

  defp parse_testcase!(path) do
    {:ok, {"testcase", attributes, children} = testcase} = path |> File.read!() |> Saxy.SimpleForm.parse_string()
    attributes = Map.new(attributes)
    documents = testcase |> child!("documents") |> elements()
    schemas = child!(testcase, "schemas")

    %{
      key: path |> Path.relative_to(@tests_dir) |> Path.rootname(),
      id: Map.fetch!(attributes, "id"),
      label: testcase |> child!("label") |> text(),
      expect: Map.get(attributes, "expect", "valid"),
      features: attributes |> Map.get("features", "") |> String.split(" ", trim: true),
      phase: schemas |> attributes() |> Map.get("phase"),
      primary: documents |> Enum.find(&match?({"primary", _attributes, _children}, &1)) |> attributes() |> Map.fetch!("filename"),
      documents: Enum.map(documents, &{&1 |> attributes() |> Map.fetch!("filename"), &1 |> elements() |> hd()}),
      schemas: elements(schemas),
      # XPath assertions over the SVRL report; recorded for the summary only.
      expectations: length(Enum.filter(children, &match?({"expectations", _attributes, _children}, &1)))
    }
  end

  defp child!({_name, _attributes, children}, name) do
    Enum.find(children, &match?({^name, _attributes, _children}, &1)) ||
      raise "missing <#{name}> in testcase"
  end

  defp elements({_name, _attributes, children}), do: Enum.filter(children, &is_tuple/1)
  defp attributes({_name, attributes, _children}), do: Map.new(attributes)
  defp text({_name, _attributes, children}), do: children |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()
end
