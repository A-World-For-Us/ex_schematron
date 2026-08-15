defmodule ExSchematron.Sch.ScopesTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Sch
  alias ExSchematron.Sch.Scopes

  defp resolve!(children) do
    """
    <schema xmlns="http://purl.oclc.org/dsdl/schematron"
      xmlns:xsl="http://www.w3.org/1999/XSL/Transform" queryBinding="xslt2">
    #{children}
    </schema>
    """
    |> Sch.parse!()
    |> Scopes.resolve!()
  end

  test "a shadowing pattern let gets its own storage key, scoped to its pattern" do
    scopes =
      resolve!("""
      <let name="foo" value="0"/>
      <pattern><let name="foo" value="1"/><rule context="*"><assert test="$foo = 1"/></rule></pattern>
      <pattern><rule context="*"><assert test="$foo = 0"/></rule></pattern>
      """)

    assert scopes.globals == [{:v_foo, {nil, "foo"}, "0"}, {:v_foo__pattern, {nil, "foo"}, "1"}]
    assert [%{bindings: %{{nil, "foo"} => :v_foo__pattern}}, %{bindings: %{{nil, "foo"} => :v_foo}}] = scopes.patterns
  end

  test "a pattern let is hoisted and visible in every pattern" do
    scopes =
      resolve!("""
      <pattern><let name="foo" value="1"/><rule context="*"><assert test="$foo"/></rule></pattern>
      <pattern><rule context="*"><assert test="$foo"/></rule></pattern>
      """)

    assert scopes.globals == [{:v_foo, {nil, "foo"}, "1"}]
    assert [%{bindings: %{{nil, "foo"} => :v_foo}}, %{bindings: %{{nil, "foo"} => :v_foo}}] = scopes.patterns
  end

  test "a variable multiply defined in one scope raises" do
    assert_raise Sch.Error, ~r/variable \$id multiply defined in rule "\*"/, fn ->
      resolve!("""
      <pattern><rule context="*">
        <let name="id" value="1"/><let name="id" value="1"/><assert test="$id"/>
      </rule></pattern>
      """)
    end

    assert_raise Sch.Error, ~r/variable \$id multiply defined in schema/, fn ->
      resolve!(~s(<let name="id" value="1"/><let name="id" value="1"/>))
    end
  end

  test "distinct names colliding on the same storage key raise" do
    assert_raise Sch.Error, ~r/variables \$foo-bar and \$foo_bar collide on storage key :v_foo_bar/, fn ->
      resolve!(~s(<let name="foo-bar" value="1"/><let name="foo_bar" value="2"/>))
    end

    # var_key case-folds, the schematron names are case-sensitive.
    assert_raise Sch.Error, ~r/variables \$Total and \$total collide/, fn ->
      resolve!(~s(<let name="Total" value="1"/><let name="total" value="2"/>))
    end

    # Across the hoisted pattern lets too: the two would share one globals key.
    assert_raise Sch.Error, ~r/collide on storage key :v_foo_bar in the schema globals/, fn ->
      resolve!("""
      <pattern><let name="foo-bar" value="1"/><rule context="*"><assert test="true()"/></rule></pattern>
      <pattern><let name="foo_bar" value="2"/><rule context="*"><assert test="true()"/></rule></pattern>
      """)
    end
  end

  test "a duplicate xsl:variable or xsl:param in a function raises" do
    assert_raise Sch.Error, ~r/variable \$x multiply defined in function my:f/, fn ->
      resolve!("""
      <xsl:function name="my:f">
        <xsl:param name="x"/>
        <xsl:variable name="x" select="1"/>
        <xsl:sequence select="$x"/>
      </xsl:function>
      """)
    end
  end

  test "pattern lets with the same name but different values raise" do
    assert_raise Sch.Error, ~r/pattern let \$foo declared with different values/, fn ->
      resolve!("""
      <pattern><let name="foo" value="1"/><rule context="*"><assert test="$foo"/></rule></pattern>
      <pattern><let name="foo" value="2"/><rule context="*"><assert test="$foo"/></rule></pattern>
      """)
    end
  end
end
