defmodule ExSchematron.Sch do
  @moduledoc """
  Parses an ISO Schematron file (xslt2 query binding) into structs.

  Parsing is strict on purpose: any element or attribute outside the supported
  subset raises, so a new schematron construct fails the build instead of being
  silently skipped.

  `<include href="..."/>` is resolved wherever it appears (schema, pattern,
  rule, phase): the root element of the included file takes the place of the
  include, as in ISO 2016 section 5.4.4. A relative href resolves against the
  directory of the file that holds the include, so includes nest. Resolving
  needs a file on disk, hence `parse_file!/1`; `parse!/1` raises on an include.
  """

  alias ExSchematron.Xml

  @sch_ns "http://purl.oclc.org/dsdl/schematron"
  @xsl_ns "http://www.w3.org/1999/XSL/Transform"

  defmodule Error do
    defexception [:message]
  end

  defmodule Schema do
    @moduledoc """
    `base_dir` resolves relative document() references; nil when parsed from a
    string. `included_files` lists every file pulled in by an include, so a
    compiled module can recompile when one of them changes.
    """
    defstruct namespaces: %{},
              default_phase: nil,
              base_dir: nil,
              included_files: [],
              lets: [],
              functions: [],
              patterns: [],
              phases: []
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

  # Where an element comes from: its document, the directory its relative
  # includes resolve against, and the chain of files included to reach it
  # (to reject an include cycle instead of looping).
  defmodule Source do
    @moduledoc false
    defstruct [:doc, :base_dir, chain: []]
  end

  @included_files_key {__MODULE__, :included_files}

  @spec parse!(binary()) :: Schema.t()
  def parse!(sch_source), do: parse_source!(sch_source, nil, [])

  @spec parse_file!(Path.t()) :: Schema.t()
  def parse_file!(path) do
    absolute = Path.expand(path)
    schema = path |> File.read!() |> parse_source!(Path.dirname(absolute), [absolute])
    %{schema | base_dir: Path.dirname(path)}
  end

  defp parse_source!(sch_source, base_dir, chain) do
    doc = Xml.parse!(sch_source)
    [root] = Xml.children(doc, doc.root_id)
    source = %Source{doc: doc, base_dir: base_dir, chain: chain}

    unless root.name == {@sch_ns, "schema"} do
      raise Error, message: "expected a schematron <schema> root, got #{inspect(root.name)}"
    end

    query_binding = attr(source, root, "queryBinding")

    unless query_binding in ["xslt2", "xslt3"] do
      raise Error, message: "unsupported queryBinding #{inspect(query_binding)}"
    end

    # Includes are resolved deep inside the element walk; the files they pull
    # in are collected for the whole parse rather than threaded through it.
    Process.put(@included_files_key, [])

    try do
      source
      |> element_children(root)
      |> Enum.reduce(%Schema{default_phase: attr(source, root, "defaultPhase")}, fn {source, element}, schema ->
        parse_schema_child(source, element, schema)
      end)
      |> reverse_lists()
      |> Map.put(:included_files, @included_files_key |> Process.get() |> Enum.reverse() |> Enum.uniq())
    after
      Process.delete(@included_files_key)
    end
  end

  defp parse_schema_child(source, %Xml.Node{name: {@sch_ns, "ns"}} = element, schema) do
    %{schema | namespaces: Map.put(schema.namespaces, attr!(source, element, "prefix"), attr!(source, element, "uri"))}
  end

  defp parse_schema_child(source, %Xml.Node{name: {@sch_ns, "let"}} = element, schema) do
    %{schema | lets: [parse_let(source, element) | schema.lets]}
  end

  defp parse_schema_child(source, %Xml.Node{name: {@sch_ns, "pattern"}} = element, schema) do
    %{schema | patterns: [parse_pattern(source, element) | schema.patterns]}
  end

  defp parse_schema_child(source, %Xml.Node{name: {@sch_ns, "phase"}} = element, schema) do
    active =
      for {source, child} <- element_children(source, element),
          child.name == {@sch_ns, "active"},
          do: attr!(source, child, "pattern")

    %{schema | phases: [%{id: attr!(source, element, "id"), active: active} | schema.phases]}
  end

  defp parse_schema_child(source, %Xml.Node{name: {@xsl_ns, "function"}} = element, schema) do
    %{schema | functions: [parse_function(source, element) | schema.functions]}
  end

  defp parse_schema_child(_source, %Xml.Node{name: {@sch_ns, "title"}}, schema), do: schema

  defp parse_schema_child(_source, %Xml.Node{name: name}, _schema) do
    raise Error, message: "unsupported schema-level element #{inspect(name)}"
  end

  defp parse_pattern(source, pattern_element) do
    initial = %Pattern{id: attr(source, pattern_element, "id")}

    source
    |> element_children(pattern_element)
    |> Enum.reduce(initial, fn {source, element}, pattern ->
      case element.name do
        {@sch_ns, "title"} -> %{pattern | title: Xml.string_value(source.doc, element.id)}
        {@sch_ns, "let"} -> %{pattern | lets: [parse_let(source, element) | pattern.lets]}
        {@sch_ns, "rule"} -> %{pattern | rules: [parse_rule(source, element) | pattern.rules]}
        other -> raise Error, message: "unsupported pattern element #{inspect(other)} in pattern #{inspect(pattern.id)}"
      end
    end)
    |> then(fn pattern -> %{pattern | lets: Enum.reverse(pattern.lets), rules: Enum.reverse(pattern.rules)} end)
  end

  defp parse_rule(source, rule_element) do
    initial = %Rule{context: attr!(source, rule_element, "context")}

    source
    |> element_children(rule_element)
    |> Enum.reduce(initial, fn {source, element}, rule ->
      case element.name do
        {@sch_ns, "let"} -> %{rule | lets: [parse_let(source, element) | rule.lets]}
        {@sch_ns, "assert"} -> %{rule | checks: [parse_check(source, element, :assert) | rule.checks]}
        {@sch_ns, "report"} -> %{rule | checks: [parse_check(source, element, :report) | rule.checks]}
        other -> raise Error, message: "unsupported rule element #{inspect(other)} in rule #{inspect(rule.context)}"
      end
    end)
    |> then(fn rule -> %{rule | lets: Enum.reverse(rule.lets), checks: Enum.reverse(rule.checks)} end)
  end

  defp parse_check(source, check_element, type) do
    message =
      source.doc
      |> Xml.children(check_element.id)
      |> Enum.map(fn
        %Xml.Node{kind: :text, value: text} ->
          {:text, text}

        %Xml.Node{name: {@sch_ns, "value-of"}} = value_of ->
          {:value_of, attr!(source, value_of, "select")}

        # <name/> is the name of the context node, <name path="p"/> the value
        # of p (ISO 2016 Annex H clause 4): both desugar to value-of.
        %Xml.Node{name: {@sch_ns, "name"}} = name_element ->
          {:value_of, attr(source, name_element, "path") || "name()"}

        %Xml.Node{name: name} ->
          raise Error, message: "unsupported element #{inspect(name)} in message of #{inspect(attr(source, check_element, "id"))}"
      end)

    %Check{
      type: type,
      id: attr(source, check_element, "id"),
      flag: attr(source, check_element, "flag"),
      test: attr!(source, check_element, "test"),
      message: message
    }
  end

  defp parse_let(source, let_element) do
    {parse_var_name(attr!(source, let_element, "name")), attr!(source, let_element, "value")}
  end

  defp parse_function(source, function_element) do
    name = parse_var_name(attr!(source, function_element, "name"))
    children = for {_source, element} <- element_children(source, function_element), do: element

    {params, body} =
      Enum.split_while(children, fn element -> element.name == {@xsl_ns, "param"} end)

    param_names = Enum.map(params, fn param -> parse_var_name(attr!(source, param, "name")) end)

    {bindings, result} = parse_function_body(source, name, body, [])

    %Function{name: name, params: param_names, bindings: bindings, result: result}
  end

  defp parse_function_body(source, function_name, [%Xml.Node{name: {@xsl_ns, "variable"}} = element | rest], bindings) do
    binding = {parse_var_name(attr!(source, element, "name")), attr!(source, element, "select")}
    parse_function_body(source, function_name, rest, [binding | bindings])
  end

  defp parse_function_body(source, _function_name, [%Xml.Node{name: {@xsl_ns, "sequence"}} = element], bindings) do
    {Enum.reverse(bindings), attr!(source, element, "select")}
  end

  defp parse_function_body(_source, function_name, remaining, _bindings) do
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

  # The element children of `element`, each with the source it was read from:
  # an include is replaced by the root element of the file it points to.
  defp element_children(source, element) do
    for child <- Xml.children(source.doc, element.id), child.kind == :element do
      if child.name == {@sch_ns, "include"}, do: include!(source, child), else: {source, child}
    end
  end

  defp include!(source, include_element) do
    href = attr!(source, include_element, "href")

    if String.contains?(href, "#") do
      raise Error, message: "include of a fragment (#{inspect(href)}) is not supported"
    end

    unless source.base_dir do
      raise Error, message: "include #{inspect(href)} needs the schematron's directory; parse it with parse_file!/1"
    end

    path = Path.expand(href, source.base_dir)

    if path in source.chain do
      cycle = [path | source.chain] |> Enum.reverse() |> Enum.join(" -> ")
      raise Error, message: "include cycle: #{cycle}"
    end

    unless File.regular?(path) do
      raise Error, message: "included file #{path} not found"
    end

    doc = path |> File.read!() |> Xml.parse!()
    [root] = Xml.children(doc, doc.root_id)
    Process.put(@included_files_key, [path | Process.get(@included_files_key, [])])
    included = %Source{doc: doc, base_dir: Path.dirname(path), chain: [path | source.chain]}

    # An included file whose root is itself an include stands for that file.
    if root.name == {@sch_ns, "include"}, do: include!(included, root), else: {included, root}
  end

  defp attr(source, element, name) do
    case Enum.find(Xml.attributes(source.doc, element.id), fn attr -> attr.name == {nil, name} end) do
      nil -> nil
      found -> found.value
    end
  end

  defp attr!(source, element, name) do
    attr(source, element, name) || raise(Error, message: "missing attribute #{inspect(name)} on #{inspect(element.name)}")
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
