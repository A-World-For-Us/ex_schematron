defmodule ExSchematron.Xml do
  @moduledoc """
  XML document model for the XPath runtime.

  Nodes are stored in a flat map keyed by id, where ids are assigned in
  document (pre)order: comparing ids gives document order, and `MapSet` on ids
  gives deduplication. Attributes are nodes too, ordered right after their
  owner element.
  """

  defmodule ParseError do
    defexception [:message]
  end

  defmodule Document do
    @moduledoc "name_index maps `{:element | :attribute, name}` to node ids in document order."
    defstruct nodes: %{}, root_id: nil, name_index: %{}

    @type t :: %__MODULE__{
            nodes: %{non_neg_integer() => ExSchematron.Xml.Node.t()},
            root_id: non_neg_integer(),
            name_index: %{{:element | :attribute, ExSchematron.Xml.Node.name()} => [non_neg_integer()]}
          }
  end

  defmodule Node do
    defstruct [:id, :parent_id, :kind, :name, :prefix, :value, children: []]

    @type name :: {uri :: binary() | nil, local :: binary()}
    @type t :: %__MODULE__{
            id: non_neg_integer(),
            parent_id: non_neg_integer() | nil,
            kind: :document | :element | :attribute | :text,
            name: name() | nil,
            prefix: binary() | nil,
            value: binary() | nil,
            children: [non_neg_integer()]
          }
  end

  defmodule Builder do
    @moduledoc false
    @behaviour Saxy.Handler

    @xml_ns "http://www.w3.org/XML/1998/namespace"

    @impl true
    def handle_event(:start_document, _prolog, state), do: {:ok, state}

    @impl true
    def handle_event(:end_document, _data, state), do: {:ok, state}

    @impl true
    def handle_event(:start_element, {qname, attrs}, %{stack: stack} = state) do
      parent_bindings =
        case stack do
          [{_name, _attrs, bindings, _children} | _rest] -> bindings
          [] -> %{"xml" => @xml_ns}
        end

      bindings = Enum.reduce(attrs, parent_bindings, &collect_binding/2)
      name = resolve_name(qname, bindings, :element)

      resolved_attrs =
        for {attr_qname, value} <- attrs, not xmlns_attr?(attr_qname) do
          {resolve_name(attr_qname, bindings, :attribute), prefix_of(attr_qname), value}
        end

      {:ok, %{state | stack: [{{name, prefix_of(qname)}, resolved_attrs, bindings, []} | stack]}}
    end

    @impl true
    def handle_event(:end_element, _qname, %{stack: [{{name, prefix}, attrs, _bindings, children} | rest]} = state) do
      element = {:element, name, prefix, attrs, merge_text(Enum.reverse(children))}

      case rest do
        [] ->
          {:ok, %{state | stack: [], root: element}}

        [{p_name, p_attrs, p_bindings, p_children} | tail] ->
          {:ok, %{state | stack: [{p_name, p_attrs, p_bindings, [element | p_children]} | tail]}}
      end
    end

    @impl true
    def handle_event(:characters, chars, %{stack: [{name, attrs, bindings, children} | rest]} = state) do
      {:ok, %{state | stack: [{name, attrs, bindings, [{:text, chars} | children]} | rest]}}
    end

    def handle_event(:characters, _chars, %{stack: []} = state), do: {:ok, state}

    @impl true
    def handle_event(:cdata, chars, state), do: handle_event(:characters, chars, state)

    defp collect_binding({"xmlns", ""}, bindings), do: Map.put(bindings, :default, nil)
    defp collect_binding({"xmlns", uri}, bindings), do: Map.put(bindings, :default, uri)
    defp collect_binding({"xmlns:" <> prefix, uri}, bindings), do: Map.put(bindings, prefix, uri)
    defp collect_binding(_attr, bindings), do: bindings

    defp xmlns_attr?("xmlns"), do: true
    defp xmlns_attr?("xmlns:" <> _prefix), do: true
    defp xmlns_attr?(_qname), do: false

    defp prefix_of(qname) do
      case String.split(qname, ":", parts: 2) do
        [_local] -> nil
        [prefix, _local] -> prefix
      end
    end

    defp resolve_name(qname, bindings, kind) do
      case String.split(qname, ":", parts: 2) do
        [local] when kind == :element ->
          {Map.get(bindings, :default), local}

        [local] ->
          {nil, local}

        [prefix, local] ->
          case Map.fetch(bindings, prefix) do
            {:ok, uri} -> {uri, local}
            :error -> raise ExSchematron.Xml.ParseError, message: "undeclared namespace prefix #{inspect(prefix)} in #{inspect(qname)}"
          end
      end
    end

    # Saxy may emit consecutive character events (entities, CDATA); XPath sees one text node.
    defp merge_text([{:text, first}, {:text, second} | rest]), do: merge_text([{:text, first <> second} | rest])
    defp merge_text([head | rest]), do: [head | merge_text(rest)]
    defp merge_text([]), do: []
  end

  @doc "Parses an XML binary into a document. Raises `#{inspect(__MODULE__)}.ParseError` on malformed input."
  @spec parse!(binary()) :: Document.t()
  def parse!(xml) when is_binary(xml) do
    case xml |> strip_bom() |> Saxy.parse_string(Builder, %{stack: [], root: nil}) do
      {:ok, %{root: root}} when root != nil -> index(root)
      {:ok, _no_root} -> raise ParseError, message: "document has no root element"
      {:error, error} -> raise ParseError, message: Exception.message(error)
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(xml), do: xml

  # Id 0 is the XPath document node: "/" selects it, the root element is its child.
  defp index(root_tree) do
    {element_id, nodes, _next_id} = index_node(root_tree, 0, 1, %{})
    document = %Node{id: 0, parent_id: nil, kind: :document, children: [element_id]}
    nodes = Map.put(nodes, 0, document)

    name_index =
      nodes
      |> Enum.sort()
      |> Enum.reduce(%{}, fn {id, node}, index ->
        case node.kind do
          kind when kind in [:element, :attribute] -> Map.update(index, {kind, node.name}, [id], &[id | &1])
          _other -> index
        end
      end)
      |> Map.new(fn {key, ids} -> {key, Enum.reverse(ids)} end)

    %Document{nodes: nodes, root_id: 0, name_index: name_index}
  end

  defp index_node({:element, name, prefix, attrs, children}, parent_id, id, nodes) do
    {attr_ids, next_id, nodes} =
      Enum.reduce(attrs, {[], id + 1, nodes}, fn {attr_name, attr_prefix, value}, {ids, attr_id, acc} ->
        attr_node = %Node{id: attr_id, parent_id: id, kind: :attribute, name: attr_name, prefix: attr_prefix, value: value}
        {[attr_id | ids], attr_id + 1, Map.put(acc, attr_id, attr_node)}
      end)

    {child_ids, next_id, nodes} =
      Enum.reduce(children, {[], next_id, nodes}, fn child, {ids, child_id, acc} ->
        {new_id, acc, following_id} = index_child(child, id, child_id, acc)
        {[new_id | ids], following_id, acc}
      end)

    node = %Node{
      id: id,
      parent_id: parent_id,
      kind: :element,
      name: name,
      prefix: prefix,
      children: Enum.reverse(attr_ids) ++ Enum.reverse(child_ids)
    }

    {id, Map.put(nodes, id, node), next_id}
  end

  defp index_child({:element, _name, _prefix, _attrs, _children} = element, parent_id, id, nodes) do
    {new_id, nodes, next_id} = index_node(element, parent_id, id, nodes)
    {new_id, nodes, next_id}
  end

  defp index_child({:text, value}, parent_id, id, nodes) do
    node = %Node{id: id, parent_id: parent_id, kind: :text, value: value}
    {id, Map.put(nodes, id, node), id + 1}
  end

  @spec node(Document.t(), non_neg_integer()) :: Node.t()
  def node(%Document{nodes: nodes}, id), do: Map.fetch!(nodes, id)

  @doc "Child nodes (elements and text), attributes excluded."
  @spec children(Document.t(), non_neg_integer()) :: [Node.t()]
  def children(doc, id) do
    for child_id <- node(doc, id).children, child = node(doc, child_id), child.kind != :attribute, do: child
  end

  @spec attributes(Document.t(), non_neg_integer()) :: [Node.t()]
  def attributes(doc, id) do
    for child_id <- node(doc, id).children, child = node(doc, child_id), child.kind == :attribute, do: child
  end

  @spec parent(Document.t(), non_neg_integer()) :: Node.t() | nil
  def parent(doc, id) do
    case node(doc, id).parent_id do
      nil -> nil
      parent_id -> node(doc, parent_id)
    end
  end

  @spec string_value(Document.t(), non_neg_integer()) :: binary()
  def string_value(doc, id) do
    case node(doc, id) do
      %Node{kind: kind} = container when kind in [:element, :document] -> container |> descendant_text(doc) |> IO.iodata_to_binary()
      %Node{value: value} -> value
    end
  end

  defp descendant_text(%Node{kind: :text, value: value}, _doc), do: value
  defp descendant_text(%Node{kind: :attribute}, _doc), do: []

  defp descendant_text(%Node{} = element, doc) do
    for child_id <- element.children, do: descendant_text(node(doc, child_id), doc)
  end
end
