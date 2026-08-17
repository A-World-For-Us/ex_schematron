defmodule ExSchematron.XmlTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Xml

  @cii_ns "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
  @ram_ns "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"

  @sample """
  <?xml version="1.0" encoding="UTF-8"?>
  <rsm:CrossIndustryInvoice xmlns:rsm="#{@cii_ns}" xmlns:ram="#{@ram_ns}">
    <rsm:ExchangedDocument>
      <ram:ID>FAC-2026-001</ram:ID>
      <ram:TypeCode listID="1001">380</ram:TypeCode>
    </rsm:ExchangedDocument>
  </rsm:CrossIndustryInvoice>
  """

  test "resolves namespaces on elements" do
    doc = Xml.parse!(@sample)
    root = doc |> Xml.children(doc.root_id) |> hd()

    assert root.name == {@cii_ns, "CrossIndustryInvoice"}
    assert root.kind == :element

    [exchanged_document] = for child <- Xml.children(doc, root.id), child.kind == :element, do: child
    assert exchanged_document.name == {@cii_ns, "ExchangedDocument"}
  end

  test "ids follow document order" do
    doc = Xml.parse!(@sample)
    root = doc |> Xml.children(doc.root_id) |> hd()

    elements = collect_elements(doc, root)
    ids = for element <- elements, do: element.id

    assert ids == Enum.sort(ids)

    assert Enum.map(elements, fn element -> elem(element.name, 1) end) ==
             ~w(CrossIndustryInvoice ExchangedDocument ID TypeCode)
  end

  test "unprefixed attributes have no namespace" do
    doc = Xml.parse!(@sample)
    [type_code] = find_elements(doc, "TypeCode")

    assert [%Xml.Node{kind: :attribute, name: {nil, "listID"}, value: "1001"}] = Xml.attributes(doc, type_code.id)
  end

  test "string_value concatenates descendant text" do
    doc = Xml.parse!(@sample)

    [id_element] = find_elements(doc, "ID")
    assert Xml.string_value(doc, id_element.id) == "FAC-2026-001"

    [exchanged_document] = find_elements(doc, "ExchangedDocument")
    assert Xml.string_value(doc, exchanged_document.id) =~ "FAC-2026-001"
    assert Xml.string_value(doc, exchanged_document.id) =~ "380"
  end

  test "parent navigation" do
    doc = Xml.parse!(@sample)
    [id_element] = find_elements(doc, "ID")

    parent = Xml.parent(doc, id_element.id)
    assert parent.name == {@cii_ns, "ExchangedDocument"}
    assert Xml.parent(doc, doc.root_id) == nil
  end

  test "default namespace applies to elements, not attributes" do
    doc = Xml.parse!(~s(<Invoice xmlns="urn:ubl" currency="EUR"><ID>1</ID></Invoice>))
    root = doc |> Xml.children(doc.root_id) |> hd()

    assert root.name == {"urn:ubl", "Invoice"}
    assert [%Xml.Node{name: {nil, "currency"}}] = Xml.attributes(doc, root.id)
    [id_element] = find_elements(doc, "ID")
    assert id_element.name == {"urn:ubl", "ID"}
  end

  test "xmlns=\"\" undeclares the default namespace" do
    doc = Xml.parse!(~s(<Invoice xmlns="urn:ubl"><Extension xmlns=""><ID>1</ID></Extension></Invoice>))

    [extension] = find_elements(doc, "Extension")
    assert extension.name == {nil, "Extension"}
    [id_element] = find_elements(doc, "ID")
    assert id_element.name == {nil, "ID"}
  end

  test "entities inside text produce a single text node" do
    doc = Xml.parse!(~s(<a>x &amp; y</a>))
    assert Xml.string_value(doc, doc.root_id) == "x & y"

    root = doc |> Xml.children(doc.root_id) |> hd()
    [text_node] = Xml.children(doc, root.id)
    assert text_node.kind == :text
    assert text_node.value == "x & y"
  end

  test "malformed XML raises a ParseError" do
    error = assert_raise Xml.ParseError, fn -> Xml.parse!("<a><b></a>") end
    assert error.message =~ "a"

    assert_raise Xml.ParseError, fn -> Xml.parse!("not xml at all") end
  end

  test "an undeclared namespace prefix raises a ParseError" do
    error = assert_raise Xml.ParseError, fn -> Xml.parse!("<root><foo:x/></root>") end
    assert error.message =~ ~s(undeclared namespace prefix "foo")
  end

  defp collect_elements(doc, node) do
    children = for child <- Xml.children(doc, node.id), child.kind == :element, do: child
    [node | Enum.flat_map(children, fn child -> collect_elements(doc, child) end)]
  end

  defp find_elements(doc, local_name) do
    root = doc |> Xml.children(doc.root_id) |> hd()
    for element <- collect_elements(doc, root), match?({_uri, ^local_name}, element.name), do: element
  end
end
