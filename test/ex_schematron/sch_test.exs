defmodule ExSchematron.SchTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Sch

  @pilot Path.join(__DIR__, "../fixtures/schematron/flux2/20260430_BR-FR-Flux2-Schematron-CII_V1.3.1.sch")

  @minimal """
  <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
    <ns prefix="ram" uri="urn:ram"/>
    <pattern id="P1">
      <title>Titre</title>
      <rule context="ram:Invoice">
        <let name="id" value="ram:ID"/>
        <assert test="string-length($id) le 35" flag="warning" id="BR-1">
          Trop long : "<value-of select='$id'/>".
        </assert>
        <report test="ram:Legacy" id="BR-2">Legacy présent.</report>
      </rule>
    </pattern>
  </schema>
  """

  test "parses the minimal schema" do
    schema = Sch.parse!(@minimal)

    assert schema.namespaces == %{"ram" => "urn:ram"}
    assert [%Sch.Pattern{id: "P1", title: "Titre", rules: [rule]}] = schema.patterns
    assert rule.context == "ram:Invoice"
    assert rule.lets == [{{nil, "id"}, "ram:ID"}]

    assert [assert_check, report_check] = rule.checks
    assert %Sch.Check{type: :assert, id: "BR-1", flag: "warning", test: "string-length($id) le 35"} = assert_check
    assert [{:text, _before}, {:value_of, "$id"}, {:text, _after}] = assert_check.message
    assert %Sch.Check{type: :report, id: "BR-2"} = report_check
  end

  test "name in a message desugars to value-of" do
    with_names =
      String.replace(
        @minimal,
        "<report test=\"ram:Legacy\" id=\"BR-2\">Legacy présent.</report>",
        "<report test=\"ram:Legacy\" id=\"BR-2\">Dans <name/> : <name path=\"@attr\"/>.</report>"
      )

    schema = Sch.parse!(with_names)
    [%Sch.Pattern{rules: [rule]}] = schema.patterns
    report = List.last(rule.checks)

    assert [{:text, _}, {:value_of, "name()"}, {:text, _}, {:value_of, "@attr"}, {:text, _}] = report.message
  end

  test "raises on unsupported constructs" do
    unsupported = String.replace(@minimal, "<title>Titre</title>", "<include href='other.sch'/>")
    assert_raise Sch.Error, ~r/unsupported pattern element/, fn -> Sch.parse!(unsupported) end
  end

  test "raises when a variable is multiply defined in one scope" do
    duplicated =
      String.replace(@minimal, ~s(<let name="id" value="ram:ID"/>), ~s(<let name="id" value="ram:ID"/><let name="id" value="ram:ID"/>))

    assert_raise Sch.Error, ~r/variable \$id multiply defined in rule/, fn -> Sch.parse!(duplicated) end
  end

  test "shadowing a let of an outer scope stays legal" do
    shadowing =
      String.replace(
        @minimal,
        "<pattern id=\"P1\">",
        "<let name='id' value=\"'global'\"/><pattern id=\"P1\"><let name='id' value=\"'pattern'\"/>"
      )

    schema = Sch.parse!(shadowing)
    assert [{{nil, "id"}, "'global'"}] = schema.lets
    assert [%Sch.Pattern{lets: [{{nil, "id"}, "'pattern'"}]}] = schema.patterns
  end

  test "raises on unsupported query binding" do
    xslt1 = String.replace(@minimal, ~s(queryBinding="xslt2"), ~s(queryBinding="xslt"))
    assert_raise Sch.Error, ~r/queryBinding/, fn -> Sch.parse!(xslt1) end
  end

  @tag :corpus
  test "parses the pilot BR-FR-Flux2-CII file" do
    schema = Sch.parse_file!(@pilot)

    assert map_size(schema.namespaces) == 5
    assert length(schema.functions) == 16
    assert length(schema.patterns) == 53

    rules = Enum.flat_map(schema.patterns, & &1.rules)
    checks = Enum.flat_map(rules, & &1.checks)
    assert length(rules) == 137
    assert length(checks) == 164
    assert Enum.all?(checks, &(&1.type == :assert))

    date_function = Enum.find(schema.functions, &(&1.name == {"custom", "is-valid-date-format"}))
    assert length(date_function.bindings) == 7
    assert date_function.result =~ "$isFormatValid and $day le $maxDay"
  end
end
