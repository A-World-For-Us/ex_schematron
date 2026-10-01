defmodule ExSchematron.OracleSuite do
  @moduledoc """
  Configuration of the differential-oracle pairs: which schematron fixture runs
  against which invoice fixtures, and which reference XSLT produces the Saxon
  verdicts. Shared by the replayable test (`test/ex_schematron/oracle_test.exs`)
  and the manifest refresh tool (`scripts/refresh_oracle.exs`).
  """

  @fixtures Path.join(File.cwd!(), "test/fixtures")

  @pairs [
    %{
      key: :flux2_cii,
      sch: "flux2/BR-FR-Flux2-Schematron-CII.sch",
      xsl: "CII/EN16931/2xslt/BR-FR-Flux2-Schematron-CII.xslt",
      profiles: [:cii_en16931, :cii_extended]
    },
    %{
      key: :flux2_cii_warning,
      sch: "flux2/BR-FR-Flux2-Schematron-CII_WARNING.sch",
      xsl: "CII/EN16931/2xslt/BR-FR-Flux2-Schematron-CII_WARNING.xslt",
      profiles: [:cii_en16931, :cii_extended]
    },
    %{
      key: :flux2_ubl,
      sch: "flux2/BR-FR-Flux2-Schematron-UBL.sch",
      xsl: "UBL/EN16931/2xslt/BR-FR-Flux2-Schematron-UBL.xslt",
      profiles: [:ubl_en16931, :ubl_extended]
    },
    %{
      key: :flux2_ubl_warning,
      sch: "flux2/BR-FR-Flux2-Schematron-UBL_WARNING.sch",
      xsl: "UBL/EN16931/2xslt/BR-FR-Flux2-Schematron-UBL_WARNING.xslt",
      profiles: [:ubl_en16931, :ubl_extended]
    },
    %{
      key: :en16931_cii,
      sch: "en16931/EN16931-CII-validation-preprocessed.sch",
      xsl: "CII/EN16931/2xslt/EN16931-CII-validation.xslt",
      profiles: [:cii_en16931]
    },
    %{
      key: :en16931_ubl,
      sch: "en16931/EN16931-UBL-validation-preprocessed.sch",
      xsl: "UBL/EN16931/2xslt/EN16931-UBL-validation.xslt",
      profiles: [:ubl_en16931]
    },
    %{
      key: :extended_ctc_cii,
      sch: "extended_ctc_fr/EXTENDED-CTC-FR-CII.sch",
      xsl: "CII/EXTENDED-CTC-FR/2xslt/EXTENDED-CTC-FR-CII.xslt",
      profiles: [:cii_extended]
    },
    %{
      key: :extended_ctc_ubl,
      sch: "extended_ctc_fr/EXTENDED-CTC-FR-UBL.sch",
      xsl: "UBL/EXTENDED-CTC-FR/2xslt/EXTENDED-CTC-FR-UBL.xslt",
      profiles: [:ubl_extended]
    },
    %{
      key: :fx_basicwl,
      sch: "facturx/FACTUR-X_BASIC-WL.sch",
      xsl: "Factur-X/BASICWL/2xslt/FACTUR-X_BASIC-WL.xslt",
      profiles: [:fx_basicwl]
    },
    %{
      key: :fx_en16931,
      sch: "facturx/FACTUR-X_EN16931.sch",
      xsl: "Factur-X/EN16931/2xslt/FACTUR-X_EN16931.xslt",
      profiles: [:cii_en16931]
    },
    %{
      key: :fx_extended,
      sch: "facturx/FACTUR-X_EXTENDED.sch",
      xsl: "Factur-X/EXTENDED/2xslt/FACTUR-X_EXTENDED.xslt",
      profiles: [:fx_extended]
    },
    %{
      key: :cdar,
      sch: "cdar/BR-FR-CDV-Schematron-CDAR.sch",
      xsl: "CDAR/2xslt/BR-FR-CDV-Schematron-CDAR.xslt",
      profiles: [:cdar]
    },
    %{
      key: :cdar_warning,
      sch: "cdar/BR-FR-CDV-Schematron-CDAR_WARNING.sch",
      xsl: "CDAR/2xslt/BR-FR-CDV-Schematron-CDAR_WARNING.xslt",
      profiles: [:cdar]
    }
  ]

  @compile_only [%{key: :flux10, sch: "flux10/Flux10.sch"}]

  @doc """
  The oracle pairs, each carrying the invoice fixtures of its profiles. A file
  added to or removed from a profile directory drifts against the frozen
  manifest, which is how the corpus stays in step with what is replayed.
  """
  def pairs do
    Enum.map(@pairs, fn pair ->
      pair
      |> Map.delete(:profiles)
      |> Map.put(:invoices, Enum.flat_map(pair.profiles, &profile_invoices/1))
    end)
  end

  @doc """
  Schematrons compiled but not replayed against Saxon: the FNFE corpus ships no
  example document for them, so there is nothing to mutate.
  """
  def compile_only, do: @compile_only

  defp profile_invoices(profile) do
    root = Path.join(@fixtures, "invoices")

    [root, Atom.to_string(profile), "*.xml"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  def sch_path(pair), do: Path.join([@fixtures, "schematron", pair.sch])
  def validator(pair), do: Module.concat(ExSchematron.OracleValidators, Macro.camelize(Atom.to_string(pair.key)))
  def invoice_path(invoice), do: Path.join([@fixtures, "invoices", invoice])
  def manifest_path(pair), do: Path.join([@fixtures, "oracle", "#{pair.key}.exs"])

  @doc "All mutants for a pair, the pristine invoices included as `<base>__orig`."
  def mutants(pair) do
    Enum.flat_map(pair.invoices, fn invoice ->
      source = invoice |> invoice_path() |> File.read!()
      base = Path.basename(invoice, ".xml")
      [{String.replace(base, ~r/[^A-Za-z0-9_-]/, "") <> "__orig", source} | ExSchematron.Mutator.mutants(source, base)]
    end)
  end

  @doc "Assert ids written in a pair's schematron (some corpora carry none)."
  def authored_ids(pair) do
    schema = pair |> sch_path() |> ExSchematron.Sch.parse_file!()

    for pattern <- schema.patterns,
        rule <- pattern.rules,
        check <- rule.checks,
        check.id != nil,
        into: MapSet.new(),
        do: check.id
  end

  @doc """
  Our validator's outcome for one document, in manifest form: the sorted
  comparison keys of its violations. A rule that raised at runtime yields a
  tagged tuple instead -- runtime errors are never frozen, so the outcome
  always drifts against the manifest.
  """
  def observed_verdict(module, xml, authored_ids) do
    violations = module.validate(xml)
    errors = for violation <- violations, violation.type == :error, do: violation.message

    keys =
      for violation <- violations, violation.type != :error do
        verdict_key(violation.flag, violation.rule, violation.test, authored_ids)
      end

    case errors do
      [] -> Enum.sort(keys)
      _some -> {:runtime_errors, errors, Enum.sort(keys)}
    end
  end

  @doc "Freezes a pair's Saxon verdicts into its manifest, sorted and stable."
  def write_manifest!(pair, verdicts) do
    ExSchematron.FrozenCorpus.write!(manifest_path(pair), verdicts,
      header: """
      Frozen Saxon verdicts of the #{pair.key} oracle pair: one entry per mutant,
      the sorted comparison keys of its failed asserts and successful reports.
      Replayed by `test/ex_schematron/oracle_test.exs`; regenerate with
      `MIX_ENV=test mix run scripts/refresh_oracle.exs #{pair.key}`.
      """
    )
  end

  @doc """
  Comparison key of one verdict, `"<flag>:<identity>"`. The flag is part of the
  key because the corpus ships WARNING variants that differ from their FATAL
  twin by nothing else; without it their manifests would be identical and the
  variants would assert nothing.

  Reference XSLTs may synthesize ids absent from the schematron source
  (Factur-X); those cannot be reproduced, so the identity is the authored id
  when the schematron has one, and a digest of the test expression otherwise --
  both sides can compute that.
  """
  def verdict_key(flag, id, test, authored_ids) do
    identity =
      if id != nil and MapSet.member?(authored_ids, id) do
        id
      else
        # Reference XSLTs may diverge textually from the schematron source: some
        # rename the code-list file they were compiled with, and XSLT 1.0 curly
        # braces (attribute value templates) swallow regex quantifier braces in
        # the SVRL @test. Neither is part of the check's identity.
        normalized =
          test
          |> String.replace(~r/document\('[^']*'\)/, "document('#')")
          |> String.replace(["{", "}"], "")
          |> String.split(~r/\s+/u, trim: true)
          |> Enum.join(" ")

        "test:" <> (:md5 |> :crypto.hash(normalized) |> Base.encode16(case: :lower) |> binary_part(0, 12))
      end

    "#{flag}:#{identity}"
  end
end
