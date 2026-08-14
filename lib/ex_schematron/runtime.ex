defmodule ExSchematron.Runtime do
  @moduledoc """
  XPath 2.0/3.1 data-model semantics for generated validation modules.

  Every compiled expression evaluates to a *sequence* (an Elixir list). Items:

    * `{:node, id}` — node in the `ExSchematron.Xml.Document`
    * `binary` — xs:string
    * `{:untyped, binary}` — xs:untypedAtomic (atomized node in an untyped document)
    * `integer` — xs:integer
    * `%Decimal{}` — xs:decimal
    * `float` / `:nan` / `:infinity` / `:neg_infinity` — xs:double
    * `true` / `false` — xs:boolean
    * `{:date, %Date{}}` — xs:date

  All the semantics that make naive translations wrong live here, once:
  existential general comparison, untypedAtomic coercion, empty-sequence
  propagation, exact decimals, document order and deduplication.
  """

  alias ExSchematron.Xml

  defmodule Error do
    defexception [:message]
  end

  @type item :: term()
  @type seq :: [item()]

  defguardp is_node_item(item) when is_tuple(item) and elem(item, 0) == :node

  # ---------------------------------------------------------------- boolean

  @doc "Effective boolean value (fn:boolean)."
  @spec ebv(seq()) :: boolean()
  def ebv([]), do: false
  def ebv([first | _rest]) when is_node_item(first), do: true
  def ebv([single]), do: item_ebv(single)
  def ebv(_multiple), do: raise(Error, message: "effective boolean value of a sequence of several atomic items")

  defp item_ebv(bool) when is_boolean(bool), do: bool
  defp item_ebv(string) when is_binary(string), do: string != ""
  defp item_ebv({:untyped, string}), do: string != ""
  defp item_ebv(int) when is_integer(int), do: int != 0
  defp item_ebv(float) when is_float(float), do: float != 0.0
  defp item_ebv(:nan), do: false
  defp item_ebv(:infinity), do: true
  defp item_ebv(:neg_infinity), do: true
  defp item_ebv(%Decimal{} = decimal), do: not Decimal.equal?(decimal, 0)
  defp item_ebv(other), do: raise(Error, message: "no effective boolean value for #{inspect(other)}")

  # ------------------------------------------------------------ atomization

  @spec atomize(Xml.Document.t(), seq()) :: seq()
  def atomize(doc, seq), do: Enum.map(seq, &atomize_item(doc, &1))

  def atomize_item(doc, {:node, id}), do: {:untyped, Xml.string_value(doc, id)}
  def atomize_item(_doc, atomic), do: atomic

  # ------------------------------------------------------------ string value

  @doc "String value of a single item (fn:string on one item)."
  @spec item_string(Xml.Document.t(), item()) :: binary()
  def item_string(doc, {:node, id}), do: Xml.string_value(doc, id)
  def item_string(_doc, {:untyped, string}), do: string
  def item_string(_doc, string) when is_binary(string), do: string
  def item_string(_doc, true), do: "true"
  def item_string(_doc, false), do: "false"
  def item_string(_doc, int) when is_integer(int), do: Integer.to_string(int)
  def item_string(_doc, %Decimal{} = decimal), do: decimal_string(decimal)
  def item_string(_doc, float) when is_float(float), do: double_string(float)
  def item_string(_doc, :nan), do: "NaN"
  def item_string(_doc, :infinity), do: "INF"
  def item_string(_doc, :neg_infinity), do: "-INF"
  def item_string(_doc, {:date, date}), do: Date.to_iso8601(date)

  defp decimal_string(decimal) do
    decimal |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  # XPath canonical xs:double: plain notation within [1e-6, 1e6), otherwise scientific.
  defp double_string(float) do
    truncated = trunc(float)

    cond do
      float == truncated and abs(float) < 1.0e18 -> Integer.to_string(truncated)
      abs(float) >= 1.0e-6 and abs(float) < 1.0e6 -> Float.to_string(float)
      true -> float |> :erlang.float_to_binary([:compact, {:scientific, 15}]) |> String.replace("e", "E")
    end
  end

  # ------------------------------------------------------------- comparison

  @doc "General comparison: existentially quantified over both atomized sequences."
  @spec general_cmp(Xml.Document.t(), atom(), seq(), seq()) :: [boolean()]
  def general_cmp(doc, op, left_seq, right_seq) do
    left_atoms = atomize(doc, left_seq)
    right_atoms = atomize(doc, right_seq)

    result =
      Enum.any?(left_atoms, fn left ->
        Enum.any?(right_atoms, fn right -> pair_cmp(op, coerce_general(left, right), coerce_general(right, left)) end)
      end)

    [result]
  end

  @doc "Value comparison (eq, ne, lt, le, gt, ge): empty propagates, singletons only."
  @spec value_cmp(Xml.Document.t(), atom(), seq(), seq()) :: [boolean()]
  def value_cmp(doc, op, left_seq, right_seq) do
    with [left] <- atomize(doc, left_seq),
         [right] <- atomize(doc, right_seq) do
      [pair_cmp(op, coerce_value(left), coerce_value(right))]
    else
      [] -> []
      _multiple -> raise Error, message: "value comparison on a sequence of several items"
    end
  end

  # In a general comparison an untyped operand takes the type of the other side.
  defp coerce_general({:untyped, string}, other) do
    cond do
      numeric?(other) -> parse_double(string)
      match?({:date, _}, other) -> cast_date(string)
      is_boolean(other) -> cast_boolean(string)
      true -> string
    end
  end

  defp coerce_general(item, _other), do: item

  # In a value comparison untypedAtomic is compared as a string.
  defp coerce_value({:untyped, string}), do: string
  defp coerce_value(item), do: item

  defp numeric?(item), do: is_number(item) or match?(%Decimal{}, item) or item in [:nan, :infinity, :neg_infinity]

  defp pair_cmp(op, left, right) do
    case compare(left, right) do
      :incomparable ->
        false

      relation ->
        case op do
          :eq -> relation == :eq
          :ne -> relation != :eq
          :lt -> relation == :lt
          :le -> relation in [:lt, :eq]
          :gt -> relation == :gt
          :ge -> relation in [:gt, :eq]
        end
    end
  end

  defp compare(left, right) when is_binary(left) and is_binary(right) do
    cond do
      left == right -> :eq
      left < right -> :lt
      true -> :gt
    end
  end

  defp compare(left, right) when is_boolean(left) and is_boolean(right) do
    cond do
      left == right -> :eq
      left -> :gt
      true -> :lt
    end
  end

  defp compare({:date, left}, {:date, right}), do: Date.compare(left, right)

  defp compare(left, right) do
    if numeric?(left) and numeric?(right) do
      numeric_compare(left, right)
    else
      raise Error, message: "cannot compare #{inspect(left)} with #{inspect(right)}"
    end
  end

  defp numeric_compare(left, right) when left in [:nan] or right in [:nan], do: :incomparable

  defp numeric_compare(left, right) when left in [:infinity, :neg_infinity] or right in [:infinity, :neg_infinity] do
    left_rank = infinity_rank(left)
    right_rank = infinity_rank(right)

    cond do
      left_rank == right_rank and is_atom(left) and is_atom(right) -> :eq
      left_rank < right_rank -> :lt
      left_rank > right_rank -> :gt
      true -> :eq
    end
  end

  defp numeric_compare(%Decimal{} = left, %Decimal{} = right), do: Decimal.compare(left, right)
  defp numeric_compare(%Decimal{} = left, right) when is_integer(right), do: Decimal.compare(left, Decimal.new(right))
  defp numeric_compare(left, %Decimal{} = right) when is_integer(left), do: Decimal.compare(Decimal.new(left), right)
  defp numeric_compare(%Decimal{} = left, right) when is_float(right), do: numeric_compare(Decimal.to_float(left), right)
  defp numeric_compare(left, %Decimal{} = right) when is_float(left), do: numeric_compare(left, Decimal.to_float(right))

  defp numeric_compare(left, right) when is_number(left) and is_number(right) do
    cond do
      left == right -> :eq
      left < right -> :lt
      true -> :gt
    end
  end

  defp infinity_rank(:neg_infinity), do: -1
  defp infinity_rank(:infinity), do: 1
  defp infinity_rank(_finite), do: 0

  @doc "Node comparison: is, << (precedes), >> (follows). Empty propagates."
  @spec node_cmp(atom(), seq(), seq()) :: [boolean()]
  def node_cmp(_op, [], _right), do: []
  def node_cmp(_op, _left, []), do: []

  def node_cmp(op, [{:node, left}], [{:node, right}]) do
    case op do
      :is -> [left == right]
      :precedes -> [left < right]
      :follows -> [left > right]
    end
  end

  def node_cmp(_op, _left, _right), do: raise(Error, message: "node comparison requires single nodes")

  # ------------------------------------------------------------- arithmetic

  @spec arith(Xml.Document.t(), atom(), seq(), seq()) :: seq()
  def arith(doc, op, left_seq, right_seq) do
    with [left] <- atomize(doc, left_seq),
         [right] <- atomize(doc, right_seq) do
      [arith_items(op, arith_operand(left), arith_operand(right))]
    else
      [] -> []
      _multiple -> raise Error, message: "arithmetic on a sequence of several items"
    end
  end

  @spec unary_minus(Xml.Document.t(), seq()) :: seq()
  def unary_minus(_doc, []), do: []
  def unary_minus(doc, seq), do: arith(doc, :-, [0], seq)

  # In arithmetic, untypedAtomic is cast to xs:double.
  defp arith_operand({:untyped, string}), do: parse_double(string)
  defp arith_operand(item) when is_number(item) or item in [:nan, :infinity, :neg_infinity], do: item
  defp arith_operand(%Decimal{} = decimal), do: decimal
  defp arith_operand(other), do: raise(Error, message: "arithmetic on non-numeric #{inspect(other)}")

  defp arith_items(_op, :nan, _right), do: :nan
  defp arith_items(_op, _left, :nan), do: :nan

  defp arith_items(op, left, right) when is_atom(left) or is_atom(right) do
    # Infinity arithmetic: only what amount checks can realistically hit.
    case op do
      :+ -> if left == :neg_infinity or right == :neg_infinity, do: :neg_infinity, else: :infinity
      :- -> arith_items(:+, left, negate_infinity(right))
      _other -> raise Error, message: "unsupported infinity arithmetic"
    end
  end

  defp arith_items(op, left, right) when is_float(left) or is_float(right) do
    left_float = to_float(left)
    right_float = to_float(right)

    case op do
      :+ -> left_float + right_float
      :- -> left_float - right_float
      :* -> left_float * right_float
      :div -> if right_float == 0.0, do: zero_div(left_float), else: left_float / right_float
      :idiv -> trunc(left_float / right_float)
      :mod -> :math.fmod(left_float, right_float)
    end
  end

  defp arith_items(op, left, right) when is_integer(left) and is_integer(right) do
    case op do
      :+ -> left + right
      :- -> left - right
      :* -> left * right
      :div -> Decimal.div(Decimal.new(left), Decimal.new(right))
      :idiv -> Kernel.div(left, right)
      :mod -> integer_mod(left, right)
    end
  end

  defp arith_items(op, left, right) do
    left_decimal = to_decimal(left)
    right_decimal = to_decimal(right)

    case op do
      :+ -> Decimal.add(left_decimal, right_decimal)
      :- -> Decimal.sub(left_decimal, right_decimal)
      :* -> Decimal.mult(left_decimal, right_decimal)
      :div -> Decimal.div(left_decimal, right_decimal)
      :idiv -> left_decimal |> Decimal.div_int(right_decimal) |> Decimal.to_integer()
      :mod -> Decimal.rem(left_decimal, right_decimal)
    end
  end

  # XPath mod takes the sign of the dividend, like Erlang rem (not Integer.mod).
  defp integer_mod(left, right), do: rem(left, right)

  defp negate_infinity(:infinity), do: :neg_infinity
  defp negate_infinity(:neg_infinity), do: :infinity
  defp negate_infinity(number), do: number

  defp zero_div(left) when left > 0, do: :infinity
  defp zero_div(left) when left < 0, do: :neg_infinity
  defp zero_div(_zero), do: :nan

  def to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  def to_float(number) when is_number(number), do: number * 1.0

  def to_decimal(%Decimal{} = decimal), do: decimal
  def to_decimal(int) when is_integer(int), do: Decimal.new(int)
  def to_decimal(float) when is_float(float), do: Decimal.from_float(float)

  @spec parse_double(binary()) :: float() | :nan | :infinity | :neg_infinity
  def parse_double(string) do
    case string |> String.trim() |> normalize_double_literal() |> Float.parse() do
      {float, ""} -> float
      _no_parse -> parse_special_double(String.trim(string))
    end
  end

  defp parse_special_double("INF"), do: :infinity
  defp parse_special_double("+INF"), do: :infinity
  defp parse_special_double("-INF"), do: :neg_infinity
  defp parse_special_double(_other), do: :nan

  # Float.parse rejects ".5", "5.", "1e2" (needs "1.0e2"), "+1".
  defp normalize_double_literal(string) do
    string
    |> String.replace_prefix("+", "")
    |> String.replace_prefix(".", "0.")
    |> String.replace_prefix("-.", "-0.")
    |> String.replace(~r/\.(?=[eE]|$)/, ".0")
    |> String.replace(~r/^(-?\d+)(?=[eE])/, "\\1.0")
  end

  # ------------------------------------------------------------------ casts

  @spec cast(Xml.Document.t(), seq(), {binary() | nil, binary()}, boolean()) :: seq()
  def cast(_doc, [], _type, true), do: []
  def cast(_doc, [], {_prefix, local}, false), do: raise(Error, message: "cannot cast empty sequence to xs:#{local}")

  def cast(doc, [item], {_prefix, local}, _allow_empty?), do: [cast_item(atomize_item(doc, item), local)]
  def cast(_doc, _seq, _type, _allow_empty?), do: raise(Error, message: "cast of a sequence of several items")

  @spec castable?(Xml.Document.t(), seq(), {binary() | nil, binary()}, boolean()) :: [boolean()]
  def castable?(_doc, [], _type, allow_empty?), do: [allow_empty?]

  def castable?(doc, [item], {_prefix, local}, _allow_empty?) do
    cast_item(atomize_item(doc, item), local)
    [true]
  rescue
    _error -> [false]
  end

  def castable?(_doc, _seq, _type, _allow_empty?), do: [false]

  defp cast_item(item, "decimal"), do: cast_decimal(item)
  defp cast_item(item, "integer"), do: cast_integer(item)
  defp cast_item(item, "double"), do: cast_double(item)
  defp cast_item(item, "string"), do: cast_string(item)
  defp cast_item(item, "boolean"), do: cast_boolean_item(item)
  defp cast_item(item, "date"), do: cast_date_item(item)
  defp cast_item(_item, other), do: raise(Error, message: "unsupported cast target xs:#{other}")

  defp cast_decimal({:untyped, string}), do: cast_decimal(string)
  defp cast_decimal(string) when is_binary(string), do: parse_decimal(string)
  defp cast_decimal(int) when is_integer(int), do: Decimal.new(int)
  defp cast_decimal(%Decimal{} = decimal), do: decimal
  defp cast_decimal(float) when is_float(float), do: Decimal.from_float(float)
  defp cast_decimal(true), do: Decimal.new(1)
  defp cast_decimal(false), do: Decimal.new(0)
  defp cast_decimal(other), do: raise(Error, message: "cannot cast #{inspect(other)} to xs:decimal")

  defp parse_decimal(string) do
    trimmed = String.trim(string)

    if String.match?(trimmed, ~r/^[+-]?(\d+(\.\d*)?|\.\d+)$/) do
      trimmed
      |> String.replace_prefix("+", "")
      |> String.replace_prefix(".", "0.")
      |> String.replace_prefix("-.", "-0.")
      |> String.replace_suffix(".", "")
      |> Decimal.new()
    else
      raise Error, message: "cannot cast #{inspect(string)} to xs:decimal"
    end
  end

  defp cast_integer({:untyped, string}), do: cast_integer(string)

  defp cast_integer(string) when is_binary(string) do
    case string |> String.trim() |> Integer.parse() do
      {int, ""} -> int
      _no_parse -> raise Error, message: "cannot cast #{inspect(string)} to xs:integer"
    end
  end

  defp cast_integer(int) when is_integer(int), do: int
  defp cast_integer(%Decimal{} = decimal), do: decimal |> Decimal.round(0, :down) |> Decimal.to_integer()
  defp cast_integer(float) when is_float(float), do: trunc(float)
  defp cast_integer(other), do: raise(Error, message: "cannot cast #{inspect(other)} to xs:integer")

  defp cast_double({:untyped, string}), do: cast_double_string(string)
  defp cast_double(string) when is_binary(string), do: cast_double_string(string)
  defp cast_double(number) when is_number(number), do: to_float(number)
  defp cast_double(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp cast_double(special) when special in [:nan, :infinity, :neg_infinity], do: special
  defp cast_double(other), do: raise(Error, message: "cannot cast #{inspect(other)} to xs:double")

  defp cast_double_string(string) do
    case parse_double(string) do
      :nan -> if String.trim(string) == "NaN", do: :nan, else: raise(Error, message: "cannot cast #{inspect(string)} to xs:double")
      value -> value
    end
  end

  defp cast_string(item), do: item_string(:no_doc, item)

  defp cast_boolean_item({:untyped, string}), do: cast_boolean(string)
  defp cast_boolean_item(string) when is_binary(string), do: cast_boolean(string)
  defp cast_boolean_item(bool) when is_boolean(bool), do: bool
  defp cast_boolean_item(number) when is_number(number), do: number != 0
  defp cast_boolean_item(other), do: raise(Error, message: "cannot cast #{inspect(other)} to xs:boolean")

  defp cast_boolean(string) do
    case String.trim(string) do
      truthy when truthy in ["true", "1"] -> true
      falsy when falsy in ["false", "0"] -> false
      other -> raise Error, message: "cannot cast #{inspect(other)} to xs:boolean"
    end
  end

  defp cast_date_item({:untyped, string}), do: cast_date(string)
  defp cast_date_item(string) when is_binary(string), do: cast_date(string)
  defp cast_date_item({:date, _date} = date), do: date
  defp cast_date_item(other), do: raise(Error, message: "cannot cast #{inspect(other)} to xs:date")

  defp cast_date(string) do
    case string |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> {:date, date}
      {:error, _reason} -> raise Error, message: "cannot cast #{inspect(string)} to xs:date"
    end
  end

  # ------------------------------------------------------------- navigation

  @doc "Document root as a sequence (the document node, XPath `/`)."
  @spec root(Xml.Document.t()) :: seq()
  def root(doc), do: [{:node, doc.root_id}]

  @doc "Every node id in document order (used to drive schematron rule matching)."
  @spec all_node_ids(Xml.Document.t()) :: [non_neg_integer()]
  def all_node_ids(doc), do: doc.nodes |> Map.keys() |> Enum.sort()

  @doc "Node-id membership set of a node sequence (schematron rule match sets)."
  @spec match_set(seq()) :: MapSet.t()
  def match_set(seq), do: MapSet.new(seq, fn {:node, id} -> id end)

  @doc "xsl:value-of on a sequence: space-joined string values."
  @spec value_of(Xml.Document.t(), seq()) :: binary()
  def value_of(doc, seq) do
    doc |> atomize(seq) |> Enum.map_join(" ", &item_string(doc, &1))
  end

  @doc "Builds a violation message: joins segments and collapses whitespace."
  @spec message(iodata()) :: binary()
  def message(iodata) do
    iodata |> IO.iodata_to_binary() |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")
  end

  @doc """
  Membership test against a generation-time frozen code list. Existential like a
  general comparison; returns a sequence so the caller's EBV matches the node
  sequence the original document() path expression would produce.
  """
  @spec codelist_member?(Xml.Document.t(), MapSet.t(), seq()) :: [true] | []
  def codelist_member?(doc, %MapSet{} = values, seq) do
    found = doc |> atomize(seq) |> Enum.any?(fn item -> MapSet.member?(values, item_string(doc, item)) end)
    if found, do: [true], else: []
  end

  @doc "Integer range `a to b`; empty when an operand is empty or a > b."
  @spec range(seq(), seq()) :: seq()
  def range([], _to_seq), do: []
  def range(_from_seq, []), do: []
  def range([from], [to]) when is_integer(from) and is_integer(to), do: Enum.to_list(from..to//1)
  def range(_from_seq, _to_seq), do: raise(Error, message: "range bounds must be single integers")

  @doc "XPath-like location of a node, for violation reports."
  @spec node_path(Xml.Document.t(), non_neg_integer()) :: binary()
  def node_path(doc, id) do
    case Xml.node(doc, id) do
      %Xml.Node{kind: :document} ->
        "/"

      %Xml.Node{parent_id: nil} = node ->
        "/" <> node_label(node)

      %Xml.Node{kind: :attribute} = node ->
        node_path(doc, node.parent_id) <> "/@" <> node_label(node)

      node ->
        prefix = if node.parent_id == doc.root_id, do: "", else: node_path(doc, node.parent_id)
        "#{prefix}/#{node_label(node)}[#{sibling_position(doc, node)}]"
    end
  end

  defp node_label(%Xml.Node{kind: :text}), do: "text()"
  defp node_label(%Xml.Node{prefix: nil, name: {_uri, local}}), do: local
  defp node_label(%Xml.Node{prefix: prefix, name: {_uri, local}}), do: prefix <> ":" <> local

  defp sibling_position(doc, node) do
    same_name =
      case Xml.parent(doc, node.id) do
        nil -> [node]
        parent -> for sibling <- Xml.children(doc, parent.id), sibling.kind == node.kind, sibling.name == node.name, do: sibling
      end

    Enum.find_index(same_name, fn sibling -> sibling.id == node.id end) + 1
  end

  @doc """
  One location step: for each context node (in document order), walk `axis`,
  filter by `test`, apply `predicates` with axis-local positions, then merge in
  document order without duplicates.

  `test` is pre-resolved by the generator: `{:name, uri | :any, local | :any}`,
  `:node`, `:text` or `:comment`. Each predicate is a
  `fun(item, position, size) :: seq()` closure (the document is captured).
  """
  @spec step(Xml.Document.t(), seq(), atom(), term(), [fun()]) :: seq()
  def step(doc, input, axis, test, predicates \\ []) do
    input
    |> Enum.flat_map(fn
      {:node, id} ->
        doc
        |> axis_nodes(id, axis)
        |> Enum.filter(&node_test(&1, axis, test))
        |> Enum.map(&{:node, &1.id})
        |> apply_predicates(doc, predicates)

      other ->
        raise Error, message: "path step on non-node #{inspect(other)}"
    end)
    |> document_order()
  end

  @doc "Postfix predicates on an arbitrary sequence: `expr[...]`."
  @spec filter(Xml.Document.t(), seq(), [fun()]) :: seq()
  def filter(doc, input, predicates), do: apply_predicates(input, doc, predicates)

  defp apply_predicates(items, _doc, []), do: items

  defp apply_predicates(items, doc, [predicate | rest]) do
    size = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.filter(fn {item, position} -> predicate_holds?(doc, predicate.(item, position, size), position) end)
    |> Enum.map(&elem(&1, 0))
    |> apply_predicates(doc, rest)
  end

  # A numeric predicate selects by position; anything else by effective boolean value.
  defp predicate_holds?(doc, result, position) do
    case atomize(doc, result) do
      [number] when is_integer(number) -> number == position
      [number] when is_float(number) -> number == position * 1.0
      [%Decimal{} = number] -> Decimal.equal?(number, position)
      _not_numeric -> ebv(result)
    end
  end

  @doc """
  Non-step path segment (`expr1/fn(...)`): evaluate `fun` once per context node
  in document order. All-node results are merged in document order; all-atomic
  results keep evaluation order; mixing both is an error.
  """
  @spec expr_step(Xml.Document.t(), seq(), (item() -> seq())) :: seq()
  def expr_step(_doc, input, fun) do
    results =
      Enum.flat_map(input, fn
        {:node, _id} = node -> fun.(node)
        other -> raise Error, message: "path step on non-node #{inspect(other)}"
      end)

    cond do
      Enum.all?(results, &is_node_item/1) -> document_order(results)
      Enum.any?(results, &is_node_item/1) -> raise Error, message: "path result mixes nodes and atomic values"
      true -> results
    end
  end

  @spec union(seq(), seq()) :: seq()
  def union(left, right) do
    unless Enum.all?(left, &is_node_item/1) and Enum.all?(right, &is_node_item/1) do
      raise Error, message: "union on non-node sequences"
    end

    document_order(left ++ right)
  end

  defp document_order(nodes) do
    nodes
    |> Enum.uniq()
    |> Enum.sort_by(fn {:node, id} -> id end)
  end

  # Reverse axes are produced nearest-first so positional predicates count backwards,
  # as XPath requires; `step/5` restores document order afterwards.
  defp axis_nodes(doc, id, :self), do: [Xml.node(doc, id)]
  defp axis_nodes(doc, id, :child), do: Xml.children(doc, id)
  defp axis_nodes(doc, id, :attribute), do: Xml.attributes(doc, id)
  defp axis_nodes(doc, id, :parent), do: List.wrap(Xml.parent(doc, id))
  defp axis_nodes(doc, id, :descendant), do: descendants(doc, id)
  defp axis_nodes(doc, id, :descendant_or_self), do: [Xml.node(doc, id) | descendants(doc, id)]
  defp axis_nodes(doc, id, :ancestor), do: ancestors(doc, id)
  defp axis_nodes(doc, id, :ancestor_or_self), do: [Xml.node(doc, id) | ancestors(doc, id)]

  defp axis_nodes(doc, id, :following_sibling) do
    for sibling <- siblings(doc, id), sibling.id > id, do: sibling
  end

  defp axis_nodes(doc, id, :preceding_sibling) do
    for(sibling <- siblings(doc, id), sibling.id < id, do: sibling) |> Enum.reverse()
  end

  defp axis_nodes(doc, id, :following) do
    subtree_end = subtree_end(doc, id)

    for {node_id, node} <- Enum.sort(doc.nodes), node_id > subtree_end, node.kind != :attribute, do: node
  end

  defp axis_nodes(doc, id, :preceding) do
    ancestor_ids = doc |> ancestors(id) |> MapSet.new(& &1.id)

    for {node_id, node} <- Enum.sort(doc.nodes, :desc),
        node_id < id,
        node.kind != :attribute,
        not MapSet.member?(ancestor_ids, node_id),
        do: node
  end

  defp descendants(doc, id) do
    Enum.flat_map(Xml.children(doc, id), fn child -> [child | descendants(doc, child.id)] end)
  end

  defp ancestors(doc, id) do
    case Xml.parent(doc, id) do
      nil -> []
      parent -> [parent | ancestors(doc, parent.id)]
    end
  end

  defp siblings(doc, id) do
    case Xml.parent(doc, id) do
      nil -> []
      parent -> Xml.children(doc, parent.id)
    end
  end

  # Preorder ids make a subtree a contiguous id range; its end is the last descendant.
  defp subtree_end(doc, id) do
    case Xml.node(doc, id).children do
      [] -> id
      children -> subtree_end(doc, List.last(children))
    end
  end

  defp node_test(node, axis, test) do
    principal_kind = if axis == :attribute, do: :attribute, else: :element

    case test do
      :node -> true
      :text -> node.kind == :text
      :comment -> false
      {:name, uri, local} -> node.kind == principal_kind and name_matches?(node.name, uri, local)
    end
  end

  defp name_matches?(nil, _uri, _local), do: false

  defp name_matches?({node_uri, node_local}, uri, local) do
    (uri == :any or node_uri == uri) and (local == :any or node_local == local)
  end
end
