defmodule ExSchematron.CompilerTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Compiler
  alias ExSchematron.Sch

  @sch """
  <schema xmlns="http://purl.oclc.org/dsdl/schematron"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:xs="http://www.w3.org/2001/XMLSchema"
    xmlns:custom="http://www.example.org/custom"
    queryBinding="xslt2">
    <ns prefix="custom" uri="http://www.example.org/custom"/>
    <ns prefix="inv" uri="urn:invoice"/>

    <xsl:function name="custom:is-valid-id-format" as="xs:boolean">
      <xsl:param name="id" as="xs:string?"/>
      <xsl:sequence select="matches(normalize-space($id), '^[A-Za-z0-9+\\-_/]+$') and not(ends-with($id, ' '))"/>
    </xsl:function>

    <pattern id="P-IDS">
      <rule context="inv:Invoice/inv:ID">
        <assert test="string-length(.) le 10" flag="warning" id="LEN-1">
          Identifiant trop long : "<value-of select="."/>".
        </assert>
        <assert test="custom:is-valid-id-format(.)" id="FMT-1">Format invalide.</assert>
      </rule>
    </pattern>

    <pattern id="P-TOTALS">
      <rule context="inv:Invoice">
        <let name="lineSum" value="sum(inv:Line/xs:decimal(inv:Amount))"/>
        <assert test="$lineSum = inv:Total/xs:decimal(.)" id="SUM-1">
          Total incohérent : lignes = <value-of select="$lineSum"/>, total = <value-of select="inv:Total"/>.
        </assert>
        <report test="inv:Legacy" id="LEG-1">Élément hérité présent.</report>
      </rule>
      <rule context="inv:Invoice/inv:Type">
        <assert test=". = ('380', '389')" id="TYPE-1">Type inconnu.</assert>
      </rule>
    </pattern>
  </schema>
  """

  @valid """
  <inv:Invoice xmlns:inv="urn:invoice">
    <inv:ID>FAC-1</inv:ID>
    <inv:Type>380</inv:Type>
    <inv:Line><inv:Amount>0.10</inv:Amount></inv:Line>
    <inv:Line><inv:Amount>0.20</inv:Amount></inv:Line>
    <inv:Total>0.30</inv:Total>
  </inv:Invoice>
  """

  defp compile_module!(name) do
    source = @sch |> Sch.parse!() |> then(&Compiler.compile!(&1, name))
    [{module, _binary} | _rest] = Code.compile_string(source)
    module
  end

  test "a conforming document yields no violation" do
    module = compile_module!(CompilerTestValid)
    assert module.validate(@valid) == []
  end

  test "violations carry rule id, message with value-of, and node path" do
    module = compile_module!(CompilerTestViolations)

    invalid =
      @valid
      |> String.replace("FAC-1", "IDENTIFIANT BEAUCOUP TROP LONG AVEC ESPACES")
      |> String.replace("<inv:Type>380</inv:Type>", "<inv:Type>999</inv:Type>")
      |> String.replace("<inv:Total>0.30</inv:Total>", "<inv:Total>0.31</inv:Total><inv:Legacy>x</inv:Legacy>")

    violations = module.validate(invalid)
    by_rule = Map.new(violations, fn violation -> {violation.rule, violation} end)

    assert map_size(by_rule) == 5

    assert %{type: :assert, flag: "warning", node: "/inv:Invoice[1]/inv:ID[1]"} = by_rule["LEN-1"]
    assert by_rule["LEN-1"].message =~ ~s(Identifiant trop long : "IDENTIFIANT BEAUCOUP TROP LONG AVEC ESPACES".)

    assert by_rule["FMT-1"]
    assert by_rule["TYPE-1"]
    assert %{type: :report} = by_rule["LEG-1"]

    # Decimal exactness: 0.1 + 0.2 = 0.3, so only the tampered total fails.
    assert by_rule["SUM-1"].message =~ "lignes = 0.3, total = 0.31"
  end

  test "the decimal sum check is exact, not floating point" do
    module = compile_module!(CompilerTestDecimal)
    assert [] = module.validate(@valid)
  end

  test "within a pattern only the first matching rule fires" do
    # inv:Invoice/inv:Type matches both P-TOTALS rules? No: contexts differ.
    # Guarantee instead that a node matched by rule 1 does not also run rule 2 of the same pattern.
    sch = """
    <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
      <ns prefix="inv" uri="urn:invoice"/>
      <pattern id="P">
        <rule context="inv:ID"><assert test="false()" id="FIRST">premier</assert></rule>
        <rule context="inv:Invoice/inv:ID"><assert test="false()" id="SECOND">second</assert></rule>
      </pattern>
    </schema>
    """

    source = sch |> Sch.parse!() |> then(&Compiler.compile!(&1, CompilerTestFirstMatch))
    [{module, _binary} | _rest] = Code.compile_string(source)

    rules = for violation <- module.validate(@valid), do: violation.rule
    assert rules == ["FIRST"]
  end

  test "unknown function raises at generation with the location" do
    sch = """
    <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
      <ns prefix="inv" uri="urn:invoice"/>
      <pattern id="P"><rule context="inv:ID"><assert test="frobnicate(.)" id="X">x</assert></rule></pattern>
    </schema>
    """

    assert_raise Compiler.Error, ~r/unsupported function frobnicate\/1 in check "X"/, fn ->
      sch |> Sch.parse!() |> Compiler.compile!(CompilerTestUnknownFn)
    end
  end

  test "undeclared namespace prefix raises at generation" do
    sch = """
    <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
      <pattern id="P"><rule context="foo:Bar"><assert test="true()" id="X">x</assert></rule></pattern>
    </schema>
    """

    assert_raise Compiler.Error, ~r/undeclared namespace prefix "foo"/, fn ->
      sch |> Sch.parse!() |> Compiler.compile!(CompilerTestUnknownNs)
    end
  end
end
