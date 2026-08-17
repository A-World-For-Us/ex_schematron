defmodule ExSchematron.XPath.ParserTest do
  use ExUnit.Case, async: true

  alias ExSchematron.XPath.Parser

  defp parse(source), do: Parser.parse!(source)

  describe "paths" do
    test "relative child path" do
      assert parse("ram:TypeCode") == {:path, :relative, [{:step, :child, {:name, "ram", "TypeCode"}, []}]}
    end

    test "multi-step path with attribute" do
      assert parse("ram:URIUniversalCommunication/ram:URIID/@schemeID") ==
               {:path, :relative,
                [
                  {:step, :child, {:name, "ram", "URIUniversalCommunication"}, []},
                  {:step, :child, {:name, "ram", "URIID"}, []},
                  {:step, :attribute, {:name, nil, "schemeID"}, []}
                ]}
    end

    test "absolute and descendant paths" do
      assert parse("/rsm:CrossIndustryInvoice") == {:path, :root, [{:step, :child, {:name, "rsm", "CrossIndustryInvoice"}, []}]}

      assert parse("//ram:ID") ==
               {:path, :root,
                [
                  {:step, :descendant_or_self, {:kind, :node}, []},
                  {:step, :child, {:name, "ram", "ID"}, []}
                ]}
    end

    test "explicit axes" do
      assert parse("ancestor::ram:Item") == {:path, :relative, [{:step, :ancestor, {:name, "ram", "Item"}, []}]}
      assert parse("..") == {:path, :relative, [{:step, :parent, {:kind, :node}, []}]}
      assert parse("self::node()") == {:path, :relative, [{:step, :self, {:kind, :node}, []}]}
    end

    test "predicates attach to their step" do
      assert parse("ram:Tax[ram:TypeCode = 'VAT']") ==
               {:path, :relative,
                [
                  {:step, :child, {:name, "ram", "Tax"},
                   [
                     {:cmp, :general, :eq, {:path, :relative, [{:step, :child, {:name, "ram", "TypeCode"}, []}]}, {:lit, "VAT"}}
                   ]}
                ]}
    end

    test "path continuing after a function call" do
      assert {:path, {:expr, {:fn, {nil, "current"}, []}}, [{:step, :child, {:name, "ram", "ID"}, []}]} = parse("current()/ram:ID")
    end

    test "wildcards" do
      assert parse("*") == {:path, :relative, [{:step, :child, :any_name, []}]}
      assert parse("ram:*") == {:path, :relative, [{:step, :child, {:prefix_wildcard, "ram"}, []}]}
      assert parse("*:ID") == {:path, :relative, [{:step, :child, {:local_wildcard, "ID"}, []}]}
    end
  end

  describe "operators" do
    test "general vs value comparison" do
      assert {:cmp, :general, :eq, _left, _right} = parse("ram:TypeCode = '380'")
      assert {:cmp, :value, :le, _left, _right} = parse("string-length(.) le 35")
    end

    test "keyword names are only operators in operator position" do
      assert {:cmp, :general, :eq, {:path, :relative, [{:step, :child, {:name, nil, "to"}, []}]}, {:lit, "x"}} = parse("to = 'x'")
    end

    test "arithmetic precedence and associativity" do
      assert parse("1 + 2 * 3") == {:arith, :+, {:lit, 1}, {:arith, :*, {:lit, 2}, {:lit, 3}}}
      assert parse("10 - 2 - 3") == {:arith, :-, {:arith, :-, {:lit, 10}, {:lit, 2}}, {:lit, 3}}
      assert parse("$year mod 4") == {:arith, :mod, {:var, {nil, "year"}}, {:lit, 4}}
    end

    test "or / and precedence" do
      assert {:or, {:and, _a, _b}, _c} = parse("a and b or c")
    end

    test "union" do
      assert {:union, _a, _b} = parse("ram:A | ram:B")
    end

    test "unary minus" do
      assert parse("-1") == {:unary_minus, {:lit, 1}}
    end

    test "string concatenation" do
      assert parse("'a' || 'b'") == {:concat_op, {:lit, "a"}, {:lit, "b"}}
    end
  end

  describe "expressions" do
    test "sequence literal" do
      assert parse("('B2B', 'B2C')") == {:seq, [{:lit, "B2B"}, {:lit, "B2C"}]}
      assert parse("()") == {:seq, []}
    end

    test "if then else" do
      assert {:if, {:cmp, :general, :eq, _a, _b}, {:lit, 31}, {:lit, 30}} = parse("if ($month = 1) then 31 else 30")
    end

    test "chained if else if" do
      assert {:if, _cond1, {:lit, 31}, {:if, _cond2, {:lit, 30}, {:lit, 0}}} =
               parse("if ($m = (1, 3)) then 31 else if ($m = 4) then 30 else 0")
    end

    test "for expression" do
      assert {:for, [{{nil, "x"}, _in}], {:arith, :*, {:var, {nil, "x"}}, {:lit, 2}}} =
               parse("for $x in ram:Line return $x * 2")
    end

    test "quantified expressions" do
      assert {:quant, :every, [{{nil, "r"}, _in}], _satisfies} = parse("every $r in ram:Rate satisfies $r = '20'")
      assert {:quant, :some, [{{nil, "r"}, _in}], _satisfies} = parse("some $r in ram:Rate satisfies $r = '20'")
    end

    test "function calls" do
      assert parse("normalize-space(.)") == {:fn, {nil, "normalize-space"}, [:context_item]}

      assert parse("custom:is-valid-date-format(.)") == {:fn, {"custom", "is-valid-date-format"}, [:context_item]}

      assert {:fn, {nil, "matches"}, [{:path, :relative, _steps}, {:lit, "^20"}]} = parse("matches(ram:ID, '^20')")
    end

    test "cast" do
      assert {:cast, {:fn, {nil, "string"}, [:context_item]}, {"xs", "decimal"}, false} = parse("string(.) cast as xs:decimal")
      assert {:castable, _expr, {"xs", "date"}, true} = parse(". castable as xs:date?")
    end

    test "prefixed variables" do
      assert {:fn, {nil, "tokenize"}, [{:var, {"custom", "eas-codes"}}, {:lit, "\\s+"}]} =
               parse("tokenize($custom:eas-codes, '\\s+')")
    end

    test "escaped quotes in string literals" do
      assert parse("'l''an'") == {:lit, "l'an"}
    end

    test "numeric literals" do
      assert parse("35") == {:lit, 35}
      assert Decimal.equal?(elem(parse("8.5"), 1), Decimal.new("8.5"))
    end

    test "filter on parenthesized expression" do
      assert {:filter, {:seq, [_a, _b]}, [{:lit, 1}]} = parse("('a', 'b')[1]")
    end

    test "comments are skipped" do
      assert parse("1 (: année :) + 2") == {:arith, :+, {:lit, 1}, {:lit, 2}}
    end
  end

  describe "real corpus expressions" do
    test "BR-FR-04 document type list membership" do
      assert {:cmp, :general, :eq, {:var, {nil, "code"}}, {:fn, {nil, "tokenize"}, _args}} =
               parse("$code = tokenize($custom:document-type-codes, '\\s+')")
    end

    test "isSpecialContract body" do
      source = """
      exists($context/rsm:ExchangedDocumentContext/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID)
      and (
      $context/rsm:ExchangedDocumentContext/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID = 'S8'
      or $context/rsm:ExchangedDocumentContext/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID = 'M8'
      )
      """

      assert {:and, {:fn, {nil, "exists"}, [{:path, {:expr, {:var, {nil, "context"}}}, _steps}]}, {:or, _a, _b}} = parse(source)
    end

    test "leap year expression" do
      source = "($year mod 4 = 0 and $year mod 100 != 0) or ($year mod 400 = 0)"
      assert {:or, {:and, {:cmp, :general, :eq, _m4, _z}, {:cmp, :general, :ne, _m100, _z2}}, _right} = parse(source)
    end

    test "is-valid-date-format condition" do
      assert {:and, {:fn, {nil, "matches"}, _args}, {:cmp, :value, :le, _day, _max}} =
               parse("matches($shortDate, '^20') and $day le $maxDay")
    end
  end

  describe "errors" do
    test "trailing tokens raise" do
      assert_raise Parser.Error, ~r/trailing/, fn -> parse("1 2") end
    end

    test "unknown axis raises" do
      assert_raise Parser.Error, ~r/unknown axis/, fn -> parse("sideways::foo") end
    end

    test "unterminated expression raises" do
      assert_raise Parser.Error, fn -> parse("ram:ID =") end
    end

    test "unsupported construct fails loudly, not silently" do
      assert_raise Parser.Error, fn -> parse("$x instance of xs:string") end
    end
  end
end
