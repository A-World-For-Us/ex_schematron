defmodule ExSchematron.OracleSuite do
  @moduledoc """
  Configuration of the differential-oracle pairs: which schematron fixture runs
  against which invoice fixtures, and which reference XSLT produces the Saxon
  verdicts. Shared by the replayable test (`test/ex_schematron/oracle_test.exs`)
  and the manifest refresh tool (`scripts/refresh_oracle.exs`).
  """

  @fixtures Path.join(File.cwd!(), "test/fixtures")

  @uc1_cii "UC1_F202500003_00-INV_20250701_CII_EN16931.xml"
  @uc10_cii "UC10_F202600004_MULTI-VENDEUR_CII_Commentee_EXTENDED.xml"
  @uc1_ubl "UC1_F202500003_00-INV_20250701_UBL_EN16931.xml"

  @pairs [
    %{
      key: :flux2_cii,
      sch: "flux2/20260430_BR-FR-Flux2-Schematron-CII_V1.3.1.sch",
      xsl: "2.BR-FR-CTC-Flux2-Schematron_UBL_ET_CII_FX_V1.3.1/_XSLT/20260430_BR-FR-Flux2-Schematron-CII_V1.3.1.xsl",
      invoices: [@uc1_cii, @uc10_cii]
    },
    %{
      key: :flux2_ubl,
      sch: "flux2/20260430_BR-FR-Flux2-Schematron-UBL_V1.3.1.sch",
      xsl: "2.BR-FR-CTC-Flux2-Schematron_UBL_ET_CII_FX_V1.3.1/_XSLT/20260430_BR-FR-Flux2-Schematron-UBL_V1.3.1.xsl",
      invoices: [@uc1_ubl]
    },
    %{
      key: :en16931_cii,
      sch: "en16931/EN16931-CII-validation-preprocessed.sch",
      xsl: "1a.EN16931_Schematrons_V1.3.15_CII_ET_UBL/_XSLT/EN16931-CII-validation.xslt",
      invoices: [@uc1_cii, @uc10_cii]
    },
    %{
      key: :en16931_ubl,
      sch: "en16931/EN16931-UBL-validation-preprocessed.sch",
      xsl: "1a.EN16931_Schematrons_V1.3.15_CII_ET_UBL/_XSLT/EN16931-UBL-validation.xslt",
      invoices: [@uc1_ubl]
    },
    %{
      key: :extended_ctc_cii,
      sch: "extended_ctc_fr/20260430_EXTENDED-CTC-FR-CII-V1.3.1.sch",
      xsl: "1b.EXTENDED-CTC-FR_Schematrons_V1.3.1_CII_ET_UBL/_XSLT/20260430_EXTENDED-CTC-FR-CII-V1.3.1.xsl",
      invoices: [@uc1_cii, @uc10_cii]
    },
    %{
      key: :extended_ctc_ubl,
      sch: "extended_ctc_fr/20260430_EXTENDED-CTC-FR-UBL-V1.3.1.sch",
      xsl: "1b.EXTENDED-CTC-FR_Schematrons_V1.3.1_CII_ET_UBL/_XSLT/20260430_EXTENDED-CTC-FR-UBL-V1.3.1.xsl",
      invoices: [@uc1_ubl]
    },
    %{
      key: :fx_basicwl,
      sch: "facturx/Factur-X_1.08_BASICWL.sch",
      xsl: "1c.Factur-X_XSD_et_Schematrons_V1.08/1. Factur-X_1.08_BASICWL/_XSLT_BASICWL/FACTUR-X_BASIC-WL.xslt",
      invoices: [@uc1_cii]
    },
    %{
      key: :fx_en16931,
      sch: "facturx/Factur-X_1.08_EN16931.sch",
      xsl: "1c.Factur-X_XSD_et_Schematrons_V1.08/3. Factur-X_1.08_EN16931/_XSLT_EN16931/FACTUR-X_EN16931.xslt",
      invoices: [@uc1_cii, @uc10_cii]
    },
    %{
      key: :fx_extended,
      sch: "facturx/Factur-X_1.08_EXTENDED.sch",
      xsl: "1c.Factur-X_XSD_et_Schematrons_V1.08/4. Factur-X_1.08_EXTENDED/_XSLT_EXTENDED/FACTUR-X_EXTENDED.xslt",
      invoices: [@uc1_cii, @uc10_cii]
    },
    %{
      key: :fx_multiseller,
      sch: "facturx/20260430_Factur-X_1.08_EXTENDED_Multi_Seller_Beta-V1.08.1.sch",
      xsl:
        "1c.Factur-X_XSD_et_Schematrons_V1.08/4b. Factur-X_1.08_EXTENDED_MULTI-SELLER-BETA-1.08.1/_XSLT_EXTENDED/20260430_Factur-X_1.08_EXTENDED_Multi_Seller_Beta-V1.08.1.xsl",
      invoices: [@uc10_cii]
    }
  ]

  def pairs, do: @pairs

  def sch_path(pair), do: Path.join([@fixtures, "schematron", pair.sch])
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
  Comparison key of one verdict. Reference XSLTs may synthesize ids absent from
  the schematron source (Factur-X); those cannot be reproduced, so a verdict is
  keyed by its authored id when the schematron has one, by a digest of its test
  expression otherwise -- both sides can compute that.
  """
  def verdict_key(id, test, authored_ids) do
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
  end
end
