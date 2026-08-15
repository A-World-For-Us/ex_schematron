defmodule ExSchematron.Sch do
  @moduledoc """
  Parses an ISO Schematron file (xslt2 query binding) into structs.

  Parsing is strict on purpose: any element or attribute outside the supported
  subset raises, so a new schematron construct fails the build instead of being
  silently skipped.
  """

  alias ExSchematron.Xml

  @sch_ns "http://purl.oclc.org/dsdl/schematron"
  @xsl_ns "http://www.w3.org/1999/XSL/Transform"

  defmodule Error do
    defexception [:message]
  end

  defmodule Schema do
    @moduledoc "base_dir resolves relative document() references; nil when parsed from a string."
    defstruct namespaces: %{}, default_phase: nil, base_dir: nil, lets: [], functions: [], patterns: [], phases: []
  end

  defmodule Pattern do
    defstruct [:id, :title, lets: [], rules: []]
  end

  defmodule Rule do
    defstruct [:context, lets: [], checks: []]
  end

  defmodule Check do
    @moduledoc "One assert or report. `message` is a list of `{:text, s}` and `{:value_of, xpath}` segments."
    defstruct [:type, :id, :flag, :test, message: []]
  end

  defmodule Function do
    @moduledoc "An xsl:function: bindings evaluate in order, `result` is the final xsl:sequence select."
    defstruct [:name, :result, params: [], bindings: []]
  end

  @spec parse!(binary()) :: Schema.t()
  def parse!(sch_source) do
    doc = Xml.parse!(sch_source)
    [root] = Xml.children(doc, doc.root_id)

    unless root.name == {@sch_ns, "schema"} do
      raise Error, message: "expected a schematron <schema> root, got #{inspect(root.name)}"
    end

    query_binding = attr(doc, root, "queryBinding")

    unless query_binding in ["xslt2", "xslt3"] do
      raise Error, message: "unsupported queryBinding #{inspect(query_binding)}"
    end

    doc
    |> element_children(root)
    |> Enum.reduce(%Schema{default_phase: attr(doc, root, "defaultPhase")}, fn element, schema ->
      parse_schema_child(doc, element, schema)
    end)
    |> reverse_lists()
  end

  @spec parse_file!(Path.t()) :: Schema.t()
  def parse_file!(path) do
    schema = path |> File.read!() |> parse!()
    %{schema | base_dir: Path.dirname(path)}
  end

  defp parse_schema_child(doc, %Xml.Node{name: {@sch_ns, "ns"}} = element, schema) do
    %{schema | namespaces: Map.put(schema.namespaces, attr!(doc, element, "prefix"), attr!(doc, element, "uri"))}
  end

  defp parse_schema_child(doc, %Xml.Node{name: {@sch_ns, "let"}} = element, schema) do
    %{schema | lets: add_let(schema.lets, doc, element, "schema")}
  end

  defp parse_schema_child(doc, %Xml.Node{name: {@sch_ns, "pattern"}} = element, schema) do
    %{schema | patterns: [parse_pattern(doc, element) | schema.patterns]}
  end

  defp parse_schema_child(doc, %Xml.Node{name: {@sch_ns, "phase"}} = element, schema) do
    active = for child <- element_children(doc, element), child.name == {@sch_ns, "active"}, do: attr!(doc, child, "pattern")
    %{schema | phases: [%{id: attr!(doc, element, "id"), active: active} | schema.phases]}
  end

  defp parse_schema_child(doc, %Xml.Node{name: {@xsl_ns, "function"}} = element, schema) do
    %{schema | functions: [parse_function(doc, element) | schema.functions]}
  end

  defp parse_schema_child(_doc, %Xml.Node{name: {@sch_ns, "title"}}, schema), do: schema

  defp parse_schema_child(_doc, %Xml.Node{name: name}, _schema) do
    raise Error, message: "unsupported schema-level element #{inspect(name)}"
  end

  defp parse_pattern(doc, pattern_element) do
    initial = %Pattern{id: attr(doc, pattern_element, "id")}

    doc
    |> element_children(pattern_element)
    |> Enum.reduce(initial, fn element, pattern ->
      case element.name do
        {@sch_ns, "title"} -> %{pattern | title: Xml.string_value(doc, element.id)}
        {@sch_ns, "let"} -> %{pattern | lets: add_let(pattern.lets, doc, element, "pattern #{inspect(pattern.id)}")}
        {@sch_ns, "rule"} -> %{pattern | rules: [parse_rule(doc, element) | pattern.rules]}
        other -> raise Error, message: "unsupported pattern element #{inspect(other)} in pattern #{inspect(pattern.id)}"
      end
    end)
    |> then(fn pattern -> %{pattern | lets: Enum.reverse(pattern.lets), rules: Enum.reverse(pattern.rules)} end)
  end

  defp parse_rule(doc, rule_element) do
    initial = %Rule{context: attr!(doc, rule_element, "context")}

    doc
    |> element_children(rule_element)
    |> Enum.reduce(initial, fn element, rule ->
      case element.name do
        {@sch_ns, "let"} -> %{rule | lets: add_let(rule.lets, doc, element, "rule #{inspect(rule.context)}")}
        {@sch_ns, "assert"} -> %{rule | checks: [parse_check(doc, element, :assert) | rule.checks]}
        {@sch_ns, "report"} -> %{rule | checks: [parse_check(doc, element, :report) | rule.checks]}
        other -> raise Error, message: "unsupported rule element #{inspect(other)} in rule #{inspect(rule.context)}"
      end
    end)
    |> then(fn rule -> %{rule | lets: Enum.reverse(rule.lets), checks: Enum.reverse(rule.checks)} end)
  end

  defp parse_check(doc, check_element, type) do
    message =
      doc
      |> Xml.children(check_element.id)
      |> Enum.map(fn
        %Xml.Node{kind: :text, value: text} ->
          {:text, text}

        %Xml.Node{name: {@sch_ns, "value-of"}} = value_of ->
          {:value_of, attr!(doc, value_of, "select")}

        # <name/> is the name of the context node, <name path="p"/> the value
        # of p (ISO 2016 Annex H clause 4): both desugar to value-of.
        %Xml.Node{name: {@sch_ns, "name"}} = name_element ->
          {:value_of, attr(doc, name_element, "path") || "name()"}

        %Xml.Node{name: name} ->
          raise Error, message: "unsupported element #{inspect(name)} in message of #{inspect(attr(doc, check_element, "id"))}"
      end)

    %Check{
      type: type,
      id: attr(doc, check_element, "id"),
      flag: attr(doc, check_element, "flag"),
      test: attr!(doc, check_element, "test"),
      message: message
    }
  end

  defp parse_let(doc, let_element) do
    {parse_var_name(attr!(doc, let_element, "name")), attr!(doc, let_element, "value")}
  end

  # A variable multiply defined in one scope is an error (ISO 2016 5.4.5 clause
  # 3); shadowing a let of an outer scope stays legal.
  defp add_let(lets, doc, let_element, where) do
    {{prefix, local} = name, _value} = let = parse_let(doc, let_element)

    if List.keymember?(lets, name, 0) do
      qualified = if prefix, do: "#{prefix}:#{local}", else: local
      raise Error, message: "variable $#{qualified} multiply defined in #{where}"
    end

    [let | lets]
  end

  defp parse_function(doc, function_element) do
    name = parse_var_name(attr!(doc, function_element, "name"))
    children = element_children(doc, function_element)

    {params, body} =
      Enum.split_while(children, fn element -> element.name == {@xsl_ns, "param"} end)

    param_names = Enum.map(params, fn param -> parse_var_name(attr!(doc, param, "name")) end)

    {bindings, result} = parse_function_body(doc, name, body, [])

    %Function{name: name, params: param_names, bindings: bindings, result: result}
  end

  defp parse_function_body(doc, function_name, [%Xml.Node{name: {@xsl_ns, "variable"}} = element | rest], bindings) do
    binding = {parse_var_name(attr!(doc, element, "name")), attr!(doc, element, "select")}
    parse_function_body(doc, function_name, rest, [binding | bindings])
  end

  defp parse_function_body(doc, _function_name, [%Xml.Node{name: {@xsl_ns, "sequence"}} = element], bindings) do
    {Enum.reverse(bindings), attr!(doc, element, "select")}
  end

  defp parse_function_body(_doc, function_name, remaining, _bindings) do
    shape = for element <- remaining, do: element.name

    raise Error,
      message:
        "unsupported xsl:function body in #{inspect(function_name)}: expected xsl:variable* then one final xsl:sequence, got #{inspect(shape)}"
  end

  defp parse_var_name(name_string) do
    case String.split(name_string, ":", parts: 2) do
      [local] -> {nil, local}
      [prefix, local] -> {prefix, local}
    end
  end

  defp element_children(doc, element) do
    for child <- Xml.children(doc, element.id), child.kind == :element, do: child
  end

  defp attr(doc, element, name) do
    case Enum.find(Xml.attributes(doc, element.id), fn attr -> attr.name == {nil, name} end) do
      nil -> nil
      found -> found.value
    end
  end

  defp attr!(doc, element, name) do
    attr(doc, element, name) || raise(Error, message: "missing attribute #{inspect(name)} on #{inspect(element.name)}")
  end

  defp reverse_lists(%Schema{} = schema) do
    %{
      schema
      | lets: Enum.reverse(schema.lets),
        functions: Enum.reverse(schema.functions),
        patterns: Enum.reverse(schema.patterns),
        phases: Enum.reverse(schema.phases)
    }
  end
end
