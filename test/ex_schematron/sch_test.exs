defmodule ExSchematron.SchTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Sch

  @pilot Path.join(__DIR__, "../fixtures/schematron/flux2/BR-FR-Flux2-Schematron-CII.sch")

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
    unsupported = String.replace(@minimal, "<title>Titre</title>", "<extends rule='other'/>")
    assert_raise Sch.Error, ~r/unsupported pattern element/, fn -> Sch.parse!(unsupported) end
  end

  describe "include" do
    @describetag :tmp_dir

    defp write!(dir, relative, content) do
      path = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      path
    end

    test "an included pattern of lets is a pattern of the schema, its lets hoisted", %{tmp_dir: dir} do
      write!(dir, "common.sch", """
      <?xml version="1.0" encoding="UTF-8"?>
      <pattern xmlns="http://purl.oclc.org/dsdl/schematron" id="variable-pattern">
        <!-- constants only -->
        <let name="VERSION" value="'3.0'"/>
      </pattern>
      """)

      path =
        write!(dir, "cii/main.sch", """
        <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
          <include href="../common.sch"/>
          <pattern id="main">
            <rule context="/"><assert test="$VERSION = '3.0'" id="R1">x</assert></rule>
          </pattern>
        </schema>
        """)

      schema = Sch.parse_file!(path)

      assert [%Sch.Pattern{id: "variable-pattern", lets: [{{nil, "VERSION"}, "'3.0'"}]}, %Sch.Pattern{id: "main"}] =
               schema.patterns

      assert schema.included_files == [Path.join(dir, "common.sch")]
      assert schema.base_dir == Path.join(dir, "cii")
    end

    test "nested includes resolve against the including file", %{tmp_dir: dir} do
      write!(dir, "subdir/rule.sch", """
      <rule xmlns="http://purl.oclc.org/dsdl/schematron" context="/">
        <include href="assert.sch"/>
      </rule>
      """)

      write!(dir, "subdir/assert.sch", """
      <assert xmlns="http://purl.oclc.org/dsdl/schematron" test="true()" id="A1"/>
      """)

      path =
        write!(dir, "main.sch", """
        <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2">
          <pattern><include href="subdir/rule.sch"/></pattern>
        </schema>
        """)

      schema = Sch.parse_file!(path)

      assert [%Sch.Pattern{rules: [%Sch.Rule{context: "/", checks: [%Sch.Check{id: "A1"}]}]}] = schema.patterns
      assert schema.included_files == [Path.join(dir, "subdir/rule.sch"), Path.join(dir, "subdir/assert.sch")]
    end

    test "raises on an include cycle", %{tmp_dir: dir} do
      write!(dir, "a.sch", ~s(<pattern xmlns="http://purl.oclc.org/dsdl/schematron"><include href="b.sch"/></pattern>))
      write!(dir, "b.sch", ~s(<rule xmlns="http://purl.oclc.org/dsdl/schematron" context="/"><include href="a.sch"/></rule>))

      path =
        write!(dir, "main.sch", """
        <schema xmlns="http://purl.oclc.org/dsdl/schematron" queryBinding="xslt2"><include href="a.sch"/></schema>
        """)

      assert_raise Sch.Error, ~r/include cycle/, fn -> Sch.parse_file!(path) end
    end

    test "raises on a missing file, a fragment, or a schema parsed from a string", %{tmp_dir: dir} do
      missing = write!(dir, "missing.sch", String.replace(@minimal, "<title>Titre</title>", "<include href='nope.sch'/>"))
      assert_raise Sch.Error, ~r/not found/, fn -> Sch.parse_file!(missing) end

      fragment = write!(dir, "fragment.sch", String.replace(@minimal, "<title>Titre</title>", "<include href='x.sch#p'/>"))
      assert_raise Sch.Error, ~r/fragment/, fn -> Sch.parse_file!(fragment) end

      from_string = String.replace(@minimal, "<title>Titre</title>", "<include href='other.sch'/>")
      assert_raise Sch.Error, ~r/needs the schematron's directory/, fn -> Sch.parse!(from_string) end
    end
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
    assert length(schema.functions) == 19
    assert length(schema.patterns) == 58

    rules = Enum.flat_map(schema.patterns, & &1.rules)
    checks = Enum.flat_map(rules, & &1.checks)
    assert length(rules) == 140
    assert length(checks) == 171
    assert Enum.all?(checks, &(&1.type == :assert))

    date_function = Enum.find(schema.functions, &(&1.name == {"custom", "is-valid-date-format"}))
    assert length(date_function.bindings) == 7
    assert date_function.result =~ "$isFormatValid and $day le $maxDay"
  end
end
