defmodule ExSchematron.RuntimeTest do
  use ExUnit.Case, async: true

  alias ExSchematron.Runtime
  alias ExSchematron.Runtime.Functions
  alias ExSchematron.Xml

  @doc_xml """
  <invoice>
    <line><amount>100.10</amount><qty>2</qty></line>
    <line><amount>0.20</amount><qty>3</qty></line>
    <total>100.30</total>
    <type>380</type>
    <empty></empty>
  </invoice>
  """

  setup_all do
    {:ok, doc: Xml.parse!(@doc_xml)}
  end

  describe "general comparison" do
    test "is existential over sequences", %{doc: doc} do
      amounts = descendants(doc, "amount")
      assert length(amounts) == 2

      assert Runtime.general_cmp(doc, :eq, amounts, ["0.20"]) == [true]
      assert Runtime.general_cmp(doc, :eq, amounts, ["999"]) == [false]

      # A = (x, y) means "A equals one of them", never list equality.
      types = descendants(doc, "type")
      assert Runtime.general_cmp(doc, :eq, types, ["380", "389", "393"]) == [true]
    end

    test "empty sequence never compares equal", %{doc: doc} do
      assert Runtime.general_cmp(doc, :eq, [], ["380"]) == [false]
      assert Runtime.general_cmp(doc, :ne, [], ["380"]) == [false]
      assert Runtime.general_cmp(doc, :lt, [], [1]) == [false]
    end

    test "untyped node against number coerces to double", %{doc: doc} do
      qtys = descendants(doc, "qty")
      assert Runtime.general_cmp(doc, :gt, qtys, [2]) == [true]
      assert Runtime.general_cmp(doc, :gt, qtys, [3]) == [false]
    end

    test "untyped against string compares as strings", %{doc: doc} do
      types = descendants(doc, "type")
      assert Runtime.general_cmp(doc, :eq, types, ["380"]) == [true]
      # String comparison, not numeric: "380" != "380.0"
      assert Runtime.general_cmp(doc, :eq, types, ["380.0"]) == [false]
    end
  end

  describe "empty sequence propagation" do
    test "not(()) is true" do
      assert Functions.not_(nil, []) == [true]
    end

    test "value comparison with empty operand yields empty", %{doc: doc} do
      assert Runtime.value_cmp(doc, :le, [], [35]) == []
      assert Runtime.ebv(Runtime.value_cmp(doc, :le, [], [35])) == false
    end

    test "arithmetic with empty operand yields empty", %{doc: doc} do
      assert Runtime.arith(doc, :+, [], [1]) == []
    end
  end

  describe "exact decimals" do
    test "0.1 + 0.2 equals 0.3 in decimal", %{doc: doc} do
      sum = Runtime.arith(doc, :+, [Decimal.new("0.1")], [Decimal.new("0.2")])
      assert Runtime.general_cmp(doc, :eq, sum, [Decimal.new("0.3")]) == [true]
    end

    test "decimal sum of cast amounts is exact", %{doc: doc} do
      amounts = descendants(doc, "amount")
      decimals = Enum.flat_map(amounts, fn node -> Runtime.cast(doc, [node], {"xs", "decimal"}, true) end)
      total = Functions.sum(doc, decimals)
      assert Runtime.general_cmp(doc, :eq, total, [Decimal.new("100.30")]) == [true]
    end

    test "sum of untyped nodes goes through doubles like Saxon", %{doc: doc} do
      amounts = descendants(doc, "amount")
      [total] = Functions.sum(doc, amounts)
      assert is_float(total)
    end
  end

  describe "effective boolean value" do
    test "of node sequences" do
      assert Runtime.ebv([{:node, 4}]) == true
      assert Runtime.ebv([]) == false
    end

    test "of atomics" do
      assert Runtime.ebv([""]) == false
      assert Runtime.ebv(["x"]) == true
      assert Runtime.ebv([0]) == false
      assert Runtime.ebv([:nan]) == false
      assert Runtime.ebv([Decimal.new("0.0")]) == false
    end

    test "of several atomics raises" do
      assert_raise Runtime.Error, fn -> Runtime.ebv([1, 2]) end
    end
  end

  describe "navigation" do
    test "child steps in document order", %{doc: doc} do
      lines = descendants(doc, "line")

      amounts =
        Enum.flat_map([Enum.reverse(lines)], fn reversed -> Runtime.step(doc, reversed, :child, {:name, :any, "amount"}, []) end)

      values = Enum.map(amounts, fn {:node, id} -> Xml.string_value(doc, id) end)
      assert values == ["100.10", "0.20"]
    end

    test "union deduplicates and orders", %{doc: doc} do
      lines = descendants(doc, "line")
      total = descendants(doc, "total")

      union = Runtime.union(total ++ lines, lines)
      assert union == Enum.sort_by(Enum.uniq(lines ++ total), fn {:node, id} -> id end)
    end

    test "positional predicate", %{doc: doc} do
      root_element = Runtime.step(doc, Runtime.root(doc), :child, {:name, :any, "invoice"}, [])

      first_line = Runtime.step(doc, root_element, :child, {:name, :any, "line"}, [fn _doc, _item, _pos, _size -> [1] end])

      assert [{:node, id}] = first_line
      assert Xml.string_value(doc, id) =~ "100.10"
    end

    test "parent and ancestor", %{doc: doc} do
      [amount | _rest] = descendants(doc, "amount")
      [{:node, parent_id}] = Runtime.step(doc, [amount], :parent, :node, [])
      assert Xml.node(doc, parent_id).name == {nil, "line"}

      ancestors = Runtime.step(doc, [amount], :ancestor, {:name, :any, "invoice"}, [])
      assert length(ancestors) == 1
    end
  end

  describe "functions" do
    test "normalize-space and string-length", %{doc: doc} do
      assert Functions.normalize_space(doc, ["  a  b \n c "]) == ["a b c"]
      assert Functions.string_length(doc, ["héllo"]) == [5]
      assert Functions.string_length(doc, []) == [0]
    end

    test "matches with XSD-style pattern", %{doc: doc} do
      assert Functions.matches(doc, ["FAC-001"], ["^[A-Za-z0-9+\\-_/]+$"]) == [true]
      assert Functions.matches(doc, ["FAC 001"], ["^[A-Za-z0-9+\\-_/]+$"]) == [false]
    end

    test "class subtraction is rejected", %{doc: doc} do
      assert_raise Runtime.Error, ~r/subtraction/, fn -> Functions.matches(doc, ["a"], ["[a-z-[aeiou]]"]) end
    end

    test "tokenize", %{doc: doc} do
      assert Functions.tokenize(doc, ["380 389  393"], ["\\s+"]) == ["380", "389", "393"]
      assert Functions.tokenize(doc, [""], ["\\s+"]) == []
    end

    test "replace with group reference", %{doc: doc} do
      assert Functions.replace(doc, ["12.34"], ["\\."], [""]) == ["1234"]
      assert Functions.replace(doc, ["abc"], ["(a)(b)"], ["$2$1"]) == ["bac"]
    end

    test "round is half toward positive infinity", %{doc: doc} do
      assert Functions.round_(doc, [Decimal.new("2.5")]) == [Decimal.new("3")]
      assert Functions.round_(doc, [Decimal.new("-2.5")]) == [Decimal.new("-2")]
      assert Functions.round_(doc, [2.5]) == [3.0]
      assert Functions.round_(doc, [-2.5]) == [-2.0]
    end

    test "number of garbage is NaN and comparisons with NaN are false", %{doc: doc} do
      assert Functions.number(doc, ["abc"]) == [:nan]
      assert Runtime.general_cmp(doc, :le, [:nan], [31]) == [false]
      assert Runtime.value_cmp(doc, :le, [:nan], [31]) == [false]
    end

    test "substring", %{doc: doc} do
      assert Functions.substring(doc, ["20260101120000"], [1], [8]) == ["20260101"]
      assert Functions.substring(doc, ["motor"], [2]) == ["otor"]
    end

    test "string of decimal is canonical", %{doc: doc} do
      assert Runtime.item_string(doc, Decimal.new("1.50")) == "1.5"
      assert Runtime.item_string(doc, Decimal.new("100")) == "100"
    end
  end

  describe "casts" do
    test "cast empty with ? yields empty", %{doc: doc} do
      assert Runtime.cast(doc, [], {"xs", "decimal"}, true) == []
    end

    test "castable" do
      doc = Xml.parse!("<a>2026-01-31</a>")
      dates = descendants(doc, "a")
      assert Runtime.castable?(doc, dates, {"xs", "date"}, false) == [true]

      bad = Xml.parse!("<a>2026-13-31</a>")
      assert Runtime.castable?(bad, descendants(bad, "a"), {"xs", "date"}, false) == [false]
    end

    test "cast node to decimal", %{doc: doc} do
      totals = descendants(doc, "total")
      assert [decimal] = Runtime.cast(doc, totals, {"xs", "decimal"}, false)
      assert Decimal.equal?(decimal, Decimal.new("100.30"))
    end
  end

  defp descendants(doc, local) do
    doc
    |> Runtime.root()
    |> then(fn root -> Runtime.step(doc, root, :descendant_or_self, :node, []) end)
    |> then(fn nodes -> Runtime.step(doc, nodes, :self, {:name, :any, local}, []) end)
  end
end
