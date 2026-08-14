defmodule ExSchematron.XPath.Parser do
  @moduledoc """
  Recursive-descent parser for the XPath subset used by the supported schematrons.

  Produces a tagged-tuple AST:

    * `{:seq, [expr]}` — comma sequence, `()` is `{:seq, []}`
    * `{:or, a, b}` / `{:and, a, b}`
    * `{:cmp, :general | :value | :node, op, a, b}` — op in `:eq :ne :lt :le :gt :ge :is :precedes :follows`
    * `{:concat_op, a, b}` — string `||`
    * `{:range, a, b}` — `a to b`
    * `{:arith, op, a, b}` — op in `:+ :- :* :div :idiv :mod`
    * `{:union, a, b}`
    * `{:cast, expr, type, allow_empty?}` / `{:castable, expr, type, allow_empty?}` — type `{prefix, local}`
    * `{:unary_minus, expr}`
    * `{:if, cond, then, else}`
    * `{:for, [{var, expr}], return}` / `{:quant, :some | :every, [{var, expr}], satisfies}`
    * `{:path, origin, [step]}` — origin `:root | :relative | {:expr, primary}`
    * `{:step, axis, node_test, [pred]}` — `//` desugars to a `descendant_or_self` step
    * node tests: `{:name, prefix, local}` | `:any_name` | `{:prefix_wildcard, p}` |
      `{:local_wildcard, l}` | `{:kind, :node | :text | :comment | :element | :attribute}`
    * `{:filter, primary, [pred]}` — postfix predicates on a non-step expression
    * `{:fn, {prefix, local}, [arg]}`
    * `{:var, {prefix, local}}`, `{:lit, value}`, `:context_item`
  """

  alias ExSchematron.XPath.Lexer

  defmodule Error do
    defexception [:message]
  end

  @axes %{
    "child" => :child,
    "attribute" => :attribute,
    "self" => :self,
    "parent" => :parent,
    "descendant" => :descendant,
    "descendant-or-self" => :descendant_or_self,
    "ancestor" => :ancestor,
    "ancestor-or-self" => :ancestor_or_self,
    "following-sibling" => :following_sibling,
    "preceding-sibling" => :preceding_sibling,
    "following" => :following,
    "preceding" => :preceding
  }

  @kind_tests %{"node" => :node, "text" => :text, "comment" => :comment}

  @value_comp_ops %{"eq" => :eq, "ne" => :ne, "lt" => :lt, "le" => :le, "gt" => :gt, "ge" => :ge}
  @general_comp_ops %{eq: :eq, ne: :ne, lt: :lt, le: :le, gt: :gt, ge: :ge}

  @spec parse!(binary()) :: term()
  def parse!(source) do
    tokens = Lexer.tokenize!(source)
    {ast, rest} = parse_expr(tokens)

    case rest do
      [] -> ast
      [{_tag, value, offset} | _more] -> fail("trailing #{inspect(value)}", offset)
    end
  end

  defp fail(message, offset) do
    raise Error, message: "#{message} at offset #{offset}"
  end

  defp expect(tokens, tag, what) do
    case tokens do
      [{^tag, _value, _offset} | rest] -> rest
      [{_tag, value, offset} | _rest] -> fail("expected #{what}, got #{inspect(value)}", offset)
      [] -> raise Error, message: "expected #{what}, got end of expression"
    end
  end

  defp keyword?([{:qname, {nil, word}, _offset} | _rest], word), do: true
  defp keyword?(_tokens, _word), do: false

  # --- Expr ("," sequence) ---

  defp parse_expr(tokens) do
    {first, rest} = parse_expr_single(tokens)
    parse_expr_tail(rest, [first])
  end

  defp parse_expr_tail([{:comma, _value, _offset} | rest], acc) do
    {expr, rest} = parse_expr_single(rest)
    parse_expr_tail(rest, [expr | acc])
  end

  defp parse_expr_tail(rest, [single]), do: {single, rest}
  defp parse_expr_tail(rest, acc), do: {{:seq, Enum.reverse(acc)}, rest}

  # --- ExprSingle ---

  defp parse_expr_single([{:qname, {nil, "for"}, _offset}, {:dollar, _dollar, _dollar_offset} | _rest] = tokens) do
    [_for | rest] = tokens
    {bindings, rest} = parse_bindings(rest, "return")
    rest = expect_keyword(rest, "return")
    {body, rest} = parse_expr_single(rest)
    {{:for, bindings, body}, rest}
  end

  defp parse_expr_single([{:qname, {nil, quant}, _offset}, {:dollar, _dollar, _dollar_offset} | _rest] = tokens)
       when quant in ["some", "every"] do
    [_quant | rest] = tokens
    {bindings, rest} = parse_bindings(rest, "satisfies")
    rest = expect_keyword(rest, "satisfies")
    {body, rest} = parse_expr_single(rest)
    {{:quant, String.to_atom(quant), bindings, body}, rest}
  end

  defp parse_expr_single([{:qname, {nil, "if"}, _offset}, {:lparen, _paren, _paren_offset} | rest]) do
    {condition, rest} = parse_expr(rest)
    rest = expect(rest, :rparen, ")")
    rest = expect_keyword(rest, "then")
    {then_expr, rest} = parse_expr_single(rest)
    rest = expect_keyword(rest, "else")
    {else_expr, rest} = parse_expr_single(rest)
    {{:if, condition, then_expr, else_expr}, rest}
  end

  defp parse_expr_single(tokens), do: parse_or(tokens)

  defp parse_bindings([{:dollar, _dollar, _offset} | rest], stop_word) do
    {var, rest} = parse_var_name(rest)
    rest = expect_keyword(rest, "in")
    {expr, rest} = parse_expr_single(rest)

    case rest do
      [{:comma, _comma, _comma_offset} | more] ->
        {bindings, rest} = parse_bindings(more, stop_word)
        {[{var, expr} | bindings], rest}

      _no_more ->
        {[{var, expr}], rest}
    end
  end

  defp parse_var_name([{:qname, name, _offset} | rest]), do: {name, rest}
  defp parse_var_name([{_tag, value, offset} | _rest]), do: fail("expected variable name, got #{inspect(value)}", offset)

  defp expect_keyword(tokens, word) do
    if keyword?(tokens, word) do
      tl(tokens)
    else
      case tokens do
        [{_tag, value, offset} | _rest] -> fail("expected #{inspect(word)}, got #{inspect(value)}", offset)
        [] -> raise Error, message: "expected #{inspect(word)}, got end of expression"
      end
    end
  end

  # --- Or / And ---

  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)

    if keyword?(rest, "or") do
      {right, rest} = parse_or(tl(rest))
      {{:or, left, right}, rest}
    else
      {left, rest}
    end
  end

  defp parse_and(tokens) do
    {left, rest} = parse_comparison(tokens)

    if keyword?(rest, "and") do
      {right, rest} = parse_and(tl(rest))
      {{:and, left, right}, rest}
    else
      {left, rest}
    end
  end

  # --- Comparison (non associative) ---

  defp parse_comparison(tokens) do
    {left, rest} = parse_concat(tokens)

    case comparison_op(rest) do
      {kind, op, rest} ->
        {right, rest} = parse_concat(rest)
        {{:cmp, kind, op, left, right}, rest}

      nil ->
        {left, rest}
    end
  end

  defp comparison_op([{tag, _value, _offset} | rest]) when is_map_key(@general_comp_ops, tag) do
    {:general, Map.fetch!(@general_comp_ops, tag), rest}
  end

  defp comparison_op([{:qname, {nil, word}, _offset} | rest]) when is_map_key(@value_comp_ops, word) do
    {:value, Map.fetch!(@value_comp_ops, word), rest}
  end

  defp comparison_op([{:qname, {nil, "is"}, _offset} | rest]), do: {:node, :is, rest}
  defp comparison_op([{:precedes, _value, _offset} | rest]), do: {:node, :precedes, rest}
  defp comparison_op([{:follows, _value, _offset} | rest]), do: {:node, :follows, rest}
  defp comparison_op(_tokens), do: nil

  # --- String concatenation ---

  defp parse_concat(tokens) do
    {left, rest} = parse_range(tokens)

    case rest do
      [{:concat, _value, _offset} | more] ->
        {right, rest} = parse_concat(more)
        {{:concat_op, left, right}, rest}

      _no_concat ->
        {left, rest}
    end
  end

  # --- Range ---

  defp parse_range(tokens) do
    {left, rest} = parse_additive(tokens)

    if keyword?(rest, "to") do
      {right, rest} = parse_additive(tl(rest))
      {{:range, left, right}, rest}
    else
      {left, rest}
    end
  end

  # --- Arithmetic (left associative) ---

  defp parse_additive(tokens) do
    {left, rest} = parse_multiplicative(tokens)
    parse_additive_tail(left, rest)
  end

  defp parse_additive_tail(left, [{tag, _value, _offset} | rest]) when tag in [:plus, :minus] do
    op = if tag == :plus, do: :+, else: :-
    {right, rest} = parse_multiplicative(rest)
    parse_additive_tail({:arith, op, left, right}, rest)
  end

  defp parse_additive_tail(left, rest), do: {left, rest}

  defp parse_multiplicative(tokens) do
    {left, rest} = parse_union(tokens)
    parse_multiplicative_tail(left, rest)
  end

  defp parse_multiplicative_tail(left, [{:star, _value, _offset} | rest]) do
    {right, rest} = parse_union(rest)
    parse_multiplicative_tail({:arith, :*, left, right}, rest)
  end

  defp parse_multiplicative_tail(left, [{:qname, {nil, word}, _offset} | rest] = tokens) when word in ["div", "idiv", "mod"] do
    # Only an operator when something follows that can start an operand; guards against
    # a path step actually named div (does not happen in practice, but cheap to keep honest).
    case rest do
      [] ->
        {left, tokens}

      _operand_follows ->
        {right, rest} = parse_union(rest)
        parse_multiplicative_tail({:arith, String.to_atom(word), left, right}, rest)
    end
  end

  defp parse_multiplicative_tail(left, rest), do: {left, rest}

  # --- Union ---

  defp parse_union(tokens) do
    {left, rest} = parse_castable(tokens)

    case rest do
      [{:union, _value, _offset} | more] ->
        {right, rest} = parse_union(more)
        {{:union, left, right}, rest}

      _maybe_keyword ->
        if keyword?(rest, "union") do
          {right, rest} = parse_union(tl(rest))
          {{:union, left, right}, rest}
        else
          {left, rest}
        end
    end
  end

  # --- Castable / Cast ---

  defp parse_castable(tokens) do
    {left, rest} = parse_cast(tokens)

    if keyword?(rest, "castable") do
      rest = expect_keyword(tl(rest), "as")
      {{type, allow_empty?}, rest} = parse_single_type(rest)
      {{:castable, left, type, allow_empty?}, rest}
    else
      {left, rest}
    end
  end

  defp parse_cast(tokens) do
    {left, rest} = parse_unary(tokens)

    if keyword?(rest, "cast") do
      rest = expect_keyword(tl(rest), "as")
      {{type, allow_empty?}, rest} = parse_single_type(rest)
      {{:cast, left, type, allow_empty?}, rest}
    else
      {left, rest}
    end
  end

  defp parse_single_type([{:qname, type, _offset} | rest]) do
    case rest do
      [{:question, _value, _question_offset} | more] -> {{type, true}, more}
      _no_question -> {{type, false}, rest}
    end
  end

  defp parse_single_type([{_tag, value, offset} | _rest]), do: fail("expected type name, got #{inspect(value)}", offset)

  # --- Unary ---

  defp parse_unary([{:minus, _value, _offset} | rest]) do
    {expr, rest} = parse_unary(rest)
    {{:unary_minus, expr}, rest}
  end

  defp parse_unary([{:plus, _value, _offset} | rest]), do: parse_unary(rest)

  defp parse_unary(tokens), do: parse_path(tokens)

  # --- Paths ---

  defp parse_path([{:slash, _value, _offset} | rest]) do
    if step_start?(rest) do
      {steps, rest} = parse_relative_path(rest)
      {{:path, :root, steps}, rest}
    else
      {{:path, :root, []}, rest}
    end
  end

  defp parse_path([{:double_slash, _value, _offset} | rest]) do
    {steps, rest} = parse_relative_path(rest)
    {{:path, :root, [descendant_or_self_step() | steps]}, rest}
  end

  defp parse_path(tokens) do
    {first, rest} = parse_step_expr(tokens)
    {steps, rest} = parse_path_tail(rest, [])

    case {first, steps} do
      {{:step, _axis, _test, _preds}, _steps} -> {{:path, :relative, [first | steps]}, rest}
      {_primary, []} -> {first, rest}
      {_primary, _steps} -> {{:path, {:expr, first}, steps}, rest}
    end
  end

  defp parse_relative_path(tokens) do
    {first, rest} = parse_axis_step(tokens)
    {steps, rest} = parse_path_tail(rest, [])
    {[first | steps], rest}
  end

  defp parse_path_tail([{:slash, _value, _offset} | rest], acc) do
    {step, rest} = parse_axis_step(rest)
    parse_path_tail(rest, [step | acc])
  end

  defp parse_path_tail([{:double_slash, _value, _offset} | rest], acc) do
    {step, rest} = parse_axis_step(rest)
    parse_path_tail(rest, [step, descendant_or_self_step() | acc])
  end

  defp parse_path_tail(rest, acc), do: {Enum.reverse(acc), rest}

  defp descendant_or_self_step, do: {:step, :descendant_or_self, {:kind, :node}, []}

  # A step after "/" is usually an axis step, but XPath 2+ allows any postfix
  # expression evaluated once per context node: `ram:Percent/xs:decimal(.)`.
  # Non-step expressions are kept verbatim in the step list.
  defp parse_axis_step(tokens), do: parse_step_expr(tokens)

  defp step_start?([{tag, _value, _offset} | _rest]) do
    tag in [:qname, :star, :prefix_wildcard, :local_wildcard, :at, :dot, :dotdot]
  end

  defp step_start?(_tokens), do: false

  # --- Step or primary ---

  defp parse_step_expr([{:dotdot, _value, _offset} | rest]) do
    parse_predicates_into_step(:parent, {:kind, :node}, rest)
  end

  defp parse_step_expr([{:at, _value, _offset} | rest]) do
    {node_test, rest} = parse_node_test(rest)
    parse_predicates_into_step(:attribute, node_test, rest)
  end

  defp parse_step_expr([{:qname, {nil, axis}, _offset}, {:axis_sep, _sep, _sep_offset} | rest] = tokens) do
    case Map.fetch(@axes, axis) do
      {:ok, axis_atom} ->
        {node_test, rest} = parse_node_test(rest)
        parse_predicates_into_step(axis_atom, node_test, rest)

      :error ->
        [{_tag, _value, offset} | _rest] = tokens
        fail("unknown axis #{inspect(axis)}", offset)
    end
  end

  # Kind test in child-step position: node(), text(), comment()
  defp parse_step_expr([{:qname, {nil, kind}, _offset}, {:lparen, _paren, _paren_offset}, {:rparen, _close, _close_offset} | rest])
       when is_map_key(@kind_tests, kind) do
    parse_predicates_into_step(:child, {:kind, Map.fetch!(@kind_tests, kind)}, rest)
  end

  defp parse_step_expr([{:qname, name, _offset}, {:lparen, _paren, _paren_offset} | rest]) do
    {args, rest} = parse_args(rest)
    parse_postfix({:fn, name, args}, rest)
  end

  defp parse_step_expr([{:qname, {prefix, local}, _offset} | rest]) do
    parse_predicates_into_step(:child, {:name, prefix, local}, rest)
  end

  defp parse_step_expr([{:star, _value, _offset} | rest]) do
    parse_predicates_into_step(:child, :any_name, rest)
  end

  defp parse_step_expr([{:prefix_wildcard, prefix, _offset} | rest]) do
    parse_predicates_into_step(:child, {:prefix_wildcard, prefix}, rest)
  end

  defp parse_step_expr([{:local_wildcard, local, _offset} | rest]) do
    parse_predicates_into_step(:child, {:local_wildcard, local}, rest)
  end

  defp parse_step_expr([{:dot, _value, _offset} | rest]), do: parse_postfix(:context_item, rest)

  defp parse_step_expr([{:dollar, _value, _offset} | rest]) do
    {var, rest} = parse_var_name(rest)
    parse_postfix({:var, var}, rest)
  end

  defp parse_step_expr([{:string, value, _offset} | rest]), do: parse_postfix({:lit, value}, rest)
  defp parse_step_expr([{:integer, value, _offset} | rest]), do: parse_postfix({:lit, value}, rest)
  defp parse_step_expr([{:decimal, value, _offset} | rest]), do: parse_postfix({:lit, value}, rest)

  defp parse_step_expr([{:lparen, _value, _offset}, {:rparen, _close, _close_offset} | rest]) do
    parse_postfix({:seq, []}, rest)
  end

  defp parse_step_expr([{:lparen, _value, _offset} | rest]) do
    {expr, rest} = parse_expr(rest)
    rest = expect(rest, :rparen, ")")
    parse_postfix(expr, rest)
  end

  defp parse_step_expr([{_tag, value, offset} | _rest]), do: fail("unexpected #{inspect(value)}", offset)
  defp parse_step_expr([]), do: raise(Error, message: "unexpected end of expression")

  defp parse_node_test([{:qname, {nil, kind}, _offset}, {:lparen, _paren, _paren_offset}, {:rparen, _close, _close_offset} | rest])
       when is_map_key(@kind_tests, kind) do
    {{:kind, Map.fetch!(@kind_tests, kind)}, rest}
  end

  defp parse_node_test([{:qname, {prefix, local}, _offset} | rest]), do: {{:name, prefix, local}, rest}
  defp parse_node_test([{:star, _value, _offset} | rest]), do: {:any_name, rest}
  defp parse_node_test([{:prefix_wildcard, prefix, _offset} | rest]), do: {{:prefix_wildcard, prefix}, rest}
  defp parse_node_test([{:local_wildcard, local, _offset} | rest]), do: {{:local_wildcard, local}, rest}
  defp parse_node_test([{_tag, value, offset} | _rest]), do: fail("expected node test, got #{inspect(value)}", offset)
  defp parse_node_test([]), do: raise(Error, message: "expected node test, got end of expression")

  defp parse_predicates_into_step(axis, node_test, tokens) do
    {predicates, rest} = parse_predicates(tokens, [])
    {{:step, axis, node_test, predicates}, rest}
  end

  defp parse_predicates([{:lbracket, _value, _offset} | rest], acc) do
    {predicate, rest} = parse_expr(rest)
    rest = expect(rest, :rbracket, "]")
    parse_predicates(rest, [predicate | acc])
  end

  defp parse_predicates(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_postfix(primary, tokens) do
    {predicates, rest} = parse_predicates(tokens, [])

    case predicates do
      [] -> {primary, rest}
      _some -> {{:filter, primary, predicates}, rest}
    end
  end

  defp parse_args([{:rparen, _value, _offset} | rest]), do: {[], rest}

  defp parse_args(tokens) do
    {arg, rest} = parse_expr_single(tokens)

    case rest do
      [{:comma, _value, _offset} | more] ->
        {args, rest} = parse_args(more)
        {[arg | args], rest}

      _no_comma ->
        rest = expect(rest, :rparen, ")")
        {[arg], rest}
    end
  end
end
