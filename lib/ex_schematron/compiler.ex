defmodule ExSchematron.Compiler do
  @moduledoc """
  Compiles a parsed schematron into the body of an Elixir validation module,
  as a quoted AST ready to be injected (`use ExSchematron` / `Module.create/3`).

  The compiled module transcribes the schematron; all XPath semantics live in
  `ExSchematron.Runtime`. Compilation raises on any XPath construct, function or
  schematron form outside the supported table — never a silent skip.
  """

  alias ExSchematron.Sch
  alias ExSchematron.XPath.Parser

  # Quoting is alias-hygienic: XP./F./Xml. calls inside the quotes below expand
  # to their full module names in the emitted AST.
  alias ExSchematron.Runtime, as: XP
  alias ExSchematron.Runtime.Functions, as: F
  alias ExSchematron.Xml

  defmodule Error do
    defexception [:message]
  end

  defmodule Env do
    @moduledoc false
    defstruct ns: %{},
              vars: %{},
              functions: %{},
              base_dir: nil,
              ctx: nil,
              position: nil,
              size: nil,
              where: nil
  end

  @doc "Compiles a parsed schematron into a quoted module body defining `validate/1`."
  @spec build_body!(Sch.Schema.t()) :: Macro.t()
  def build_body!(%Sch.Schema{} = schema) do
    # Without defaultPhase the ISO default phase is #ALL: every pattern is active
    # and the phase declarations are inert, so they can be ignored safely.
    if schema.default_phase do
      raise Error, message: "schematron defaultPhase is not supported yet"
    end

    functions = Map.new(schema.functions, fn function -> {function.name, length(function.params)} end)

    base_env = %Env{ns: schema.namespaces, functions: functions, base_dir: schema.base_dir}

    # Pattern-level lets are hoisted to schema level, like SchXslt compiles them
    # (global xsl:variable): the corpus references them across pattern boundaries.
    global_lets = schema.lets ++ hoist_pattern_lets(schema.patterns)
    global_names = Enum.map(global_lets, fn {name, _value} -> name end)

    function_defs = Enum.map(schema.functions, &compile_function(&1, base_env))
    globals_def = compile_globals(global_lets, base_env)

    Process.delete({__MODULE__, :codelist_registry})

    {pattern_defs, pattern_calls} =
      schema.patterns
      |> Enum.with_index()
      |> Enum.map(fn {pattern, index} -> compile_pattern(pattern, index, base_env, global_names) end)
      |> Enum.unzip()

    codelist_definitions = codelist_defs()

    quote do
      @doc "Validates an XML binary (or parsed document). Returns every violation."
      def validate(xml) when is_binary(xml), do: validate(Xml.parse!(xml))

      def validate(%Xml.Document{} = doc) do
        globals = globals(doc)
        Enum.concat([unquote_splicing(pattern_calls)])
      end

      unquote(globals_def)

      unquote_splicing(List.flatten(pattern_defs))

      unquote_splicing(function_defs)

      unquote_splicing(codelist_definitions)

      # A schematron may declare helper functions that none of its rules call;
      # referencing them here keeps the unused-function check quiet.
      @doc false
      def __schematron_functions__ do
        unquote(Enum.map(functions, fn {name, arity} -> capture_ast(function_fun_name(name), arity + 1) end))
      end
    end
  end

  # ---------------------------------------------------------------- globals

  defp hoist_pattern_lets(patterns) do
    all_lets = for pattern <- patterns, let <- pattern.lets, do: {let, pattern.id}

    all_lets
    |> Enum.group_by(fn {{name, _value}, _pattern_id} -> name end)
    |> Enum.each(fn {name, declarations} ->
      values = declarations |> Enum.map(fn {{_name, value}, _pattern_id} -> value end) |> Enum.uniq()

      if length(values) > 1 do
        pattern_ids = Enum.map(declarations, &elem(&1, 1))
        raise Error, message: "pattern let $#{format_name(name)} declared with different values in patterns #{inspect(pattern_ids)}"
      end
    end)

    all_lets |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(fn {name, _value} -> name end)
  end

  defp compile_globals(lets, env) do
    ctx_var = Macro.var(:ctx, __MODULE__)

    {bindings, entries, _env} =
      Enum.reduce(lets, {[], [], %{env | ctx: ctx_var, where: "schema-level let"}}, fn {name, value}, {bindings, entries, env} ->
        var = let_var(name)
        expr = compile_source(value, env)
        binding = quote do: unquote(var) = unquote(expr)
        {[binding | bindings], [{var_key(name), var} | entries], put_var(env, name, var)}
      end)

    map_ast = {:%{}, [], Enum.reverse(entries)}

    quote do
      defp globals(doc) do
        unquote(ctx_var) = {:node, doc.root_id}
        _ = unquote(ctx_var)
        unquote_splicing(Enum.reverse(bindings))
        unquote(map_ast)
      end
    end
  end

  # ---------------------------------------------------------------- patterns

  defp compile_pattern(%Sch.Pattern{} = pattern, index, env, global_names) do
    pattern_fun = :"pattern_#{index}_#{sanitize(pattern.id || "anonymous")}"

    env = Enum.reduce(global_names, env, fn name, env -> put_var(env, name, quote(do: globals.unquote(let_var(name)))) end)

    rules = Enum.with_index(pattern.rules)

    rule_defs =
      Enum.map(rules, fn {rule, rule_index} ->
        compile_rule(rule, :"#{pattern_fun}_rule_#{rule_index}", env)
      end)

    # One list rather than one variable per rule: closures cannot capture more
    # than 255 free variables on the BEAM, and some patterns exceed 300 rules.
    set_exprs =
      Enum.map(rules, fn {rule, rule_index} ->
        compile_context(rule.context, %{env | where: "context of rule #{rule_index} in pattern #{inspect(pattern.id)}"})
      end)

    dispatch_clauses =
      Enum.map(rules, fn {_rule, rule_index} ->
        checks_fun = :"#{pattern_fun}_rule_#{rule_index}"
        {:->, [], [[rule_index], quote(do: unquote(checks_fun)(doc, globals, {:node, node_id}))]}
      end)

    fallback = {:->, [], [[nil], []]}
    dispatch = {:case, [], [quote(do: Enum.find_index(rule_sets, &MapSet.member?(&1, node_id))), [do: [fallback | dispatch_clauses]]]}

    pattern_def =
      quote do
        defp unquote(pattern_fun)(doc, globals) do
          rule_sets = [unquote_splicing(set_exprs)]

          Enum.flat_map(XP.matched_ids(rule_sets), fn node_id ->
            unquote(dispatch)
          end)
        end
      end

    call = quote do: unquote(pattern_fun)(doc, globals)
    {[pattern_def | rule_defs], call}
  end

  # ------------------------------------------------------------------ rules

  defp compile_rule(%Sch.Rule{} = rule, fun_name, env) do
    ctx_var = Macro.var(:ctx, __MODULE__)
    env = %{env | ctx: ctx_var, where: "rule #{inspect(rule.context)}"}

    {let_bindings, env} =
      Enum.reduce(rule.lets, {[], env}, fn {name, value}, {bindings, env} ->
        var = let_var(name)
        binding = quote do: unquote(var) = unquote(compile_source(value, env))
        {[binding | bindings], put_var(env, name, var)}
      end)

    check_exprs = Enum.map(rule.checks, &compile_check(&1, env))
    let_vars = Enum.map(rule.lets, fn {name, _value} -> let_var(name) end)

    quote do
      defp unquote(fun_name)(doc, globals, {:node, ctx_id} = unquote(ctx_var)) do
        _ = {doc, globals, ctx_id, unquote(ctx_var)}
        unquote_splicing(Enum.reverse(let_bindings))
        _ = {unquote_splicing(let_vars)}
        Enum.reject([unquote_splicing(check_exprs)], &is_nil/1)
      rescue
        error in [ExSchematron.Runtime.Error] ->
          [
            %{
              type: :error,
              rule: unquote(rule.context),
              test: nil,
              flag: nil,
              message: Exception.message(error),
              node: XP.node_path(doc, ctx_id)
            }
          ]
      end
    end
  end

  defp compile_check(%Sch.Check{} = check, env) do
    env = %{env | where: "check #{inspect(check.id)}"}
    test_expr = compile_source(check.test, env)

    message_segments =
      Enum.map(check.message, fn
        {:text, text} -> text
        {:value_of, select} -> quote do: XP.value_of(doc, unquote(compile_source(select, env)))
      end)

    violation =
      quote do
        %{
          type: unquote(check.type),
          rule: unquote(check.id),
          test: unquote(check.test),
          flag: unquote(check.flag),
          message: XP.message([unquote_splicing(message_segments)]),
          node: XP.node_path(doc, ctx_id)
        }
      end

    case check.type do
      :assert -> quote do: if(XP.ebv(unquote(test_expr)), do: nil, else: unquote(violation))
      :report -> quote do: if(XP.ebv(unquote(test_expr)), do: unquote(violation), else: nil)
    end
  end

  # A rule @context is an XSLT match pattern: unanchored paths match anywhere.
  # Compiles to a MapSet of node ids — bottom-up through the document's name
  # index whenever the pattern reduces to child/attribute name steps with
  # boolean predicates, top-down as a plain path evaluation otherwise.
  defp compile_context(context_source, env) do
    ast = parse_source(context_source, env)
    env = %{env | ctx: quote(do: {:node, doc.root_id})}
    anchored = anchor_context(ast, env)

    try do
      compile_context_reverse(anchored, env)
    catch
      :forward_fallback ->
        quote do: XP.match_set(unquote(compile_expr(anchored, env)))
    end
  end

  defp compile_context_reverse(anchored, env) do
    anchored
    |> flatten_context()
    |> Enum.map(fn steps -> compile_reverse_chain(steps, env) end)
    |> Enum.reduce(fn set_expr, acc -> quote do: MapSet.union(unquote(acc), unquote(set_expr)) end)
  end

  defp flatten_context({:union, left, right}), do: flatten_context(left) ++ flatten_context(right)
  defp flatten_context({:path, :root, steps}), do: [steps]

  defp flatten_context({:path, {:expr, inner}, steps}) do
    for inner_steps <- flatten_context(inner), do: inner_steps ++ steps
  end

  # "(...)[pred]": for boolean predicates, filtering the set is per-node, so the
  # predicates can ride on the last step of every branch.
  defp flatten_context({:filter, inner, predicates}) do
    for steps <- flatten_context(inner) do
      case List.pop_at(steps, -1) do
        {{:step, axis, test, step_predicates}, front} -> front ++ [{:step, axis, test, step_predicates ++ predicates}]
        _empty -> throw(:forward_fallback)
      end
    end
  end

  defp flatten_context(_other), do: throw(:forward_fallback)

  defp compile_reverse_chain(steps, env) do
    {absolute?, steps} =
      case steps do
        [{:step, :descendant_or_self, {:kind, :node}, []} | rest] -> {false, rest}
        _anchored_at_root -> {true, steps}
      end

    if steps == [], do: throw(:forward_fallback)

    entries =
      Enum.map(steps, fn
        {:step, :child, {:name, prefix, local}, predicates} ->
          {:element, {resolve_optional_prefix!(prefix, env), local}, predicates}

        {:step, :attribute, {:name, prefix, local}, predicates} ->
          {:attribute, {resolve_optional_prefix!(prefix, env), local}, predicates}

        _other ->
          throw(:forward_fallback)
      end)

    unless entries |> Enum.drop(-1) |> Enum.all?(&match?({:element, _name, _preds}, &1)) do
      throw(:forward_fallback)
    end

    chain =
      entries
      |> Enum.reverse()
      |> Enum.map(fn {kind, name, predicates} ->
        {:{}, [], [kind, Macro.escape(name), compile_reverse_predicates(predicates, env)]}
      end)

    quote do: XP.match_set_reverse(doc, unquote(chain), unquote(absolute?))
  end

  defp compile_reverse_predicates([], _env), do: nil

  defp compile_reverse_predicates(predicates, env) do
    if Enum.any?(predicates, fn predicate -> match?({:lit, _value}, predicate) end) do
      throw(:forward_fallback)
    end

    item_var = Macro.var(:match_item, __MODULE__)
    pred_env = %{env | ctx: item_var, position: nil, size: nil}

    compiled =
      try do
        Enum.map(predicates, fn predicate -> quote do: XP.ebv(unquote(compile_expr(predicate, pred_env))) end)
      rescue
        # position()/last() or another construct only the forward path handles.
        _error in [Error] -> throw(:forward_fallback)
      end

    conjunction = Enum.reduce(compiled, fn pred, acc -> quote do: unquote(acc) and unquote(pred) end)

    quote do
      fn unquote(item_var) ->
        _ = unquote(item_var)
        unquote(conjunction)
      end
    end
  end

  defp resolve_optional_prefix!(nil, _env), do: nil
  defp resolve_optional_prefix!(prefix, env), do: resolve_prefix!(prefix, env)

  defp anchor_context({:union, left, right}, env), do: {:union, anchor_context(left, env), anchor_context(right, env)}
  defp anchor_context({:path, :root, steps}, _env), do: {:path, :root, steps}

  defp anchor_context({:path, :relative, steps}, _env) do
    {:path, :root, [{:step, :descendant_or_self, {:kind, :node}, []} | steps]}
  end

  # "(A|B)/C" as a match pattern is any C under an A or a B anywhere: anchoring
  # distributes into the parenthesized origin, the trailing steps are unchanged.
  defp anchor_context({:path, {:expr, origin}, steps}, env) do
    {:path, {:expr, anchor_context(origin, env)}, steps}
  end

  # "(A|B)[pred]": the predicate filters the anchored set. Only boolean predicates
  # keep XSLT match semantics there; a positional one would count the whole set.
  defp anchor_context({:filter, inner, predicates}, env) do
    if Enum.any?(predicates, &match?({:lit, _value}, &1)) do
      raise Error, message: "positional predicate on a filtered rule context is not supported, in #{env.where}"
    end

    {:filter, anchor_context(inner, env), predicates}
  end

  defp anchor_context(other, env) do
    raise Error, message: "unsupported rule context form #{inspect(other)} in #{env.where}"
  end

  # ------------------------------------------------------------- xsl:function

  defp compile_function(%Sch.Function{} = function, env) do
    param_vars = Enum.map(function.params, &let_var/1)

    env =
      function.params
      |> Enum.zip(param_vars)
      |> Enum.reduce(%{env | where: "function #{format_name(function.name)}"}, fn {name, var}, env -> put_var(env, name, var) end)

    {bindings, env} =
      Enum.reduce(function.bindings, {[], env}, fn {name, value}, {bindings, env} ->
        var = let_var(name)
        binding = quote do: unquote(var) = unquote(compile_source(value, env))
        {[binding | bindings], put_var(env, name, var)}
      end)

    result = compile_source(function.result, env)
    binding_vars = Enum.map(function.bindings, fn {name, _value} -> let_var(name) end)

    quote do
      defp unquote(function_fun_name(function.name))(doc, unquote_splicing(param_vars)) do
        _ = {doc, unquote_splicing(param_vars)}
        unquote_splicing(Enum.reverse(bindings))
        _ = {unquote_splicing(binding_vars)}
        unquote(result)
      end
    end
  end

  defp function_fun_name({prefix, local}), do: :"fn_#{sanitize("#{prefix}_#{local}")}"

  defp capture_ast(fun_name, arity), do: Code.string_to_quoted!("&#{fun_name}/#{arity}")

  # ------------------------------------------------------------- expressions

  defp parse_source(source, env) do
    Parser.parse!(source)
  rescue
    error ->
      raise Error, message: "cannot parse #{inspect(source)} in #{env.where}: #{Exception.message(error)}"
  end

  defp compile_source(source, env), do: source |> parse_source(env) |> compile_expr(env)

  defp compile_expr({:lit, value}, _env) when is_binary(value) or is_integer(value), do: [value]
  defp compile_expr({:lit, %Decimal{} = decimal}, _env), do: quote(do: [Decimal.new(unquote(Decimal.to_string(decimal)))])

  defp compile_expr({:seq, exprs}, env) do
    compiled = Enum.map(exprs, &compile_expr(&1, env))
    quote do: Enum.concat([unquote_splicing(compiled)])
  end

  defp compile_expr({:or, left, right}, env) do
    quote do: [XP.ebv(unquote(compile_expr(left, env))) or XP.ebv(unquote(compile_expr(right, env)))]
  end

  defp compile_expr({:and, left, right}, env) do
    quote do: [XP.ebv(unquote(compile_expr(left, env))) and XP.ebv(unquote(compile_expr(right, env)))]
  end

  defp compile_expr({:cmp, :general, op, left, right}, env) do
    quote do: XP.general_cmp(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:cmp, :value, op, left, right}, env) do
    quote do: XP.value_cmp(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:cmp, :node, op, left, right}, env) do
    quote do: XP.node_cmp(unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:arith, op, left, right}, env) do
    quote do: XP.arith(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:unary_minus, expr}, env) do
    quote do: XP.unary_minus(doc, unquote(compile_expr(expr, env)))
  end

  defp compile_expr({:union, left, right}, env) do
    quote do: XP.union(unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:range, left, right}, env) do
    quote do: XP.range(unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp compile_expr({:concat_op, left, right}, env) do
    quote do: F.concat(doc, [unquote(compile_expr(left, env)), unquote(compile_expr(right, env))])
  end

  defp compile_expr({:if, condition, then_expr, else_expr}, env) do
    quote do
      if XP.ebv(unquote(compile_expr(condition, env))) do
        unquote(compile_expr(then_expr, env))
      else
        unquote(compile_expr(else_expr, env))
      end
    end
  end

  defp compile_expr({:for, bindings, body}, env), do: compile_for(bindings, body, env)

  defp compile_expr({:quant, kind, bindings, satisfies}, env) do
    quote do: [unquote(compile_quant(kind, bindings, satisfies, env))]
  end

  defp compile_expr({:cast, expr, type, allow_empty?}, env) do
    validate_cast_type!(type, env)
    quote do: XP.cast(doc, unquote(compile_expr(expr, env)), unquote(type), unquote(allow_empty?))
  end

  defp compile_expr({:castable, expr, type, allow_empty?}, env) do
    validate_cast_type!(type, env)
    quote do: XP.castable?(doc, unquote(compile_expr(expr, env)), unquote(type), unquote(allow_empty?))
  end

  defp compile_expr({:var, name}, env) do
    case Map.fetch(env.vars, name) do
      {:ok, var_ast} -> var_ast
      :error -> raise Error, message: "unknown variable $#{format_name(name)} in #{env.where}"
    end
  end

  defp compile_expr(:context_item, env), do: quote(do: [unquote(ctx!(env))])

  # The corpus uses document() in exactly one shape, a code-list membership test:
  # document('x_codedb.xml')/codedb/cl[@id=N]/enumeration[@value=$v]. The list is
  # frozen into the module as a MapSet at generation time; the emitted expression
  # keeps the EBV the node sequence would have ([] or a non-empty sequence).
  # Any other use of document() falls through to the unsupported-function raise.
  defp compile_expr(
         {:path, {:expr, {:fn, {nil, "document"}, [{:lit, file}]}},
          [
            {:step, :child, {:name, nil, "codedb"}, []},
            {:step, :child, {:name, nil, "cl"},
             [{:cmp, :general, :eq, {:path, :relative, [{:step, :attribute, {:name, nil, "id"}, []}]}, {:lit, cl_id}}]},
            {:step, :child, {:name, nil, "enumeration"},
             [{:cmp, :general, :eq, {:path, :relative, [{:step, :attribute, {:name, nil, "value"}, []}]}, checked_expr}]}
          ]},
         env
       )
       when is_binary(file) and is_integer(cl_id) do
    # The same code list is referenced by many checks; one shared private
    # function per list keeps the module AST small.
    fun_name = register_codelist!(file, cl_id, env)
    quote do: XP.codelist_member?(doc, unquote(fun_name)(), unquote(compile_expr(checked_expr, env)))
  end

  defp compile_expr({:path, origin, steps}, env) do
    initial =
      case origin do
        :root -> quote do: XP.root(doc)
        :relative -> quote do: [unquote(ctx!(env))]
        {:expr, expr} -> compile_expr(expr, env)
      end

    Enum.reduce(steps, initial, fn step, acc -> compile_step(step, acc, env) end)
  end

  defp compile_expr({:filter, primary, predicates}, env) do
    quote do: XP.filter(doc, unquote(compile_expr(primary, env)), unquote(compile_predicates(predicates, env)))
  end

  defp compile_expr({:fn, name, args}, env), do: compile_call(name, args, env)

  defp compile_expr(other, env) do
    raise Error, message: "unsupported XPath construct #{inspect(other)} in #{env.where}"
  end

  defp compile_step({:step, axis, node_test, predicates}, acc, env) do
    test = compile_node_test(node_test, env)
    quote do: XP.step(doc, unquote(acc), unquote(axis), unquote(Macro.escape(test)), unquote(compile_predicates(predicates, env)))
  end

  # Any other expression as a path segment: evaluated once per context node.
  defp compile_step(expr, acc, env) do
    item_var = Macro.var(:step_item, __MODULE__)
    inner = compile_expr(expr, %{env | ctx: item_var})

    quote do
      XP.expr_step(doc, unquote(acc), fn unquote(item_var) ->
        _ = unquote(item_var)
        unquote(inner)
      end)
    end
  end

  defp compile_predicates([], _env), do: []

  defp compile_predicates(predicates, env) do
    Enum.map(predicates, fn predicate ->
      item_var = Macro.var(:pred_item, __MODULE__)
      position_var = Macro.var(:pred_position, __MODULE__)
      size_var = Macro.var(:pred_size, __MODULE__)

      inner = compile_expr(predicate, %{env | ctx: item_var, position: position_var, size: size_var})

      quote do
        fn unquote(item_var), unquote(position_var), unquote(size_var) ->
          _ = {unquote(item_var), unquote(position_var), unquote(size_var)}
          unquote(inner)
        end
      end
    end)
  end

  defp compile_node_test(node_test, env) do
    case node_test do
      {:name, nil, local} -> {:name, nil, local}
      {:name, prefix, local} -> {:name, resolve_prefix!(prefix, env), local}
      :any_name -> {:name, :any, :any}
      {:prefix_wildcard, prefix} -> {:name, resolve_prefix!(prefix, env), :any}
      {:local_wildcard, local} -> {:name, :any, local}
      {:kind, kind} -> kind
    end
  end

  defp resolve_prefix!(prefix, env) do
    case Map.fetch(env.ns, prefix) do
      {:ok, uri} -> uri
      :error -> raise Error, message: "undeclared namespace prefix #{inspect(prefix)} in #{env.where}"
    end
  end

  defp compile_for([], body, env), do: compile_expr(body, env)

  defp compile_for([{name, source_expr} | rest], body, env) do
    item_var = Macro.var(:"for_#{sanitize(format_name(name))}", __MODULE__)
    inner_env = put_var(env, name, quote(do: [unquote(item_var)]))

    quote do
      Enum.flat_map(unquote(compile_expr(source_expr, env)), fn unquote(item_var) ->
        unquote(compile_for(rest, body, inner_env))
      end)
    end
  end

  defp compile_quant(_kind, [], satisfies, env), do: quote(do: XP.ebv(unquote(compile_expr(satisfies, env))))

  defp compile_quant(kind, [{name, source_expr} | rest], satisfies, env) do
    item_var = Macro.var(:"quant_#{sanitize(format_name(name))}", __MODULE__)
    inner_env = put_var(env, name, quote(do: [unquote(item_var)]))
    enum_fun = if kind == :some, do: :any?, else: :all?

    quote do
      Enum.unquote(enum_fun)(unquote(compile_expr(source_expr, env)), fn unquote(item_var) ->
        unquote(compile_quant(kind, rest, satisfies, inner_env))
      end)
    end
  end

  @cast_targets ~w(decimal integer double string boolean date)

  defp validate_cast_type!({prefix, local}, env) do
    unless prefix == "xs" and local in @cast_targets do
      raise Error, message: "unsupported cast target #{format_name({prefix, local})} in #{env.where}"
    end
  end

  # ----------------------------------------------------------- code lists

  # Compilation-scoped registry of the code lists referenced so far, so each is
  # emitted once as a private function definition.
  defp register_codelist!(file, cl_id, env) do
    key = {__MODULE__, :codelist_registry}
    registry = Process.get(key, %{})

    case Map.fetch(registry, {file, cl_id}) do
      {:ok, {fun_name, _values}} ->
        fun_name

      :error ->
        values = codelist_values!(file, cl_id, env)
        fun_name = :"codelist_#{map_size(registry)}"
        Process.put(key, Map.put(registry, {file, cl_id}, {fun_name, values}))
        fun_name
    end
  end

  defp codelist_defs do
    key = {__MODULE__, :codelist_registry}
    registry = Process.get(key, %{})
    Process.delete(key)

    for {_file_and_id, {fun_name, values}} <- Enum.sort(registry) do
      quote do
        defp unquote(fun_name)(), do: unquote(Macro.escape(values))
      end
    end
  end

  defp codelist_values!(file, cl_id, env) do
    unless env.base_dir do
      raise Error, message: "document(#{inspect(file)}) needs the schematron's directory; compile from a file path, in #{env.where}"
    end

    path = Path.join(env.base_dir, file)
    codedb = codedb_document!(path, env)

    id_string = Integer.to_string(cl_id)

    values =
      for code_list <- ExSchematron.Xml.children(codedb, hd(ExSchematron.Xml.children(codedb, codedb.root_id)).id),
          code_list.kind == :element,
          Enum.any?(ExSchematron.Xml.attributes(codedb, code_list.id), fn attr ->
            attr.name == {nil, "id"} and attr.value == id_string
          end),
          enumeration <- ExSchematron.Xml.children(codedb, code_list.id),
          enumeration.kind == :element,
          attr <- ExSchematron.Xml.attributes(codedb, enumeration.id),
          attr.name == {nil, "value"},
          into: MapSet.new(),
          do: attr.value

    if MapSet.size(values) == 0 do
      raise Error, message: "code list cl[@id=#{cl_id}] is empty or missing in #{path}, in #{env.where}"
    end

    values
  end

  # One codedb file is referenced hundreds of times; parse it once per compilation.
  defp codedb_document!(path, env) do
    key = {__MODULE__, :codedb, path}

    case Process.get(key) do
      nil ->
        unless File.exists?(path) do
          raise Error, message: "code list file #{path} not found, in #{env.where}"
        end

        codedb = path |> File.read!() |> ExSchematron.Xml.parse!()
        Process.put(key, codedb)
        codedb

      codedb ->
        codedb
    end
  end

  # ---------------------------------------------------------- function calls

  @zero_arg_context ~w(string normalize-space string-length number name local-name)

  defp compile_call({prefix, local}, args, env) when prefix in [nil, "fn"] do
    args = if local in @zero_arg_context and args == [], do: [:context_item], else: args
    compiled = Enum.map(args, &compile_expr(&1, env))
    builtin!(local, compiled, env)
  end

  defp compile_call({"xs", local}, [arg], env) when local in @cast_targets do
    # Constructor functions behave like `cast as xs:type?`.
    quote do: XP.cast(doc, unquote(compile_expr(arg, env)), {"xs", unquote(local)}, true)
  end

  defp compile_call(name, args, env) do
    arity = Map.get(env.functions, name)

    cond do
      arity == nil ->
        raise Error, message: "unknown function #{format_name(name)}() in #{env.where}"

      arity != length(args) ->
        raise Error, message: "#{format_name(name)}() expects #{arity} arguments, got #{length(args)} in #{env.where}"

      true ->
        compiled = Enum.map(args, &compile_expr(&1, env))
        quote do: unquote(function_fun_name(name))(doc, unquote_splicing(compiled))
    end
  end

  @simple_builtins %{
    {"not", 1} => :not_,
    {"boolean", 1} => :boolean_,
    {"exists", 1} => :exists,
    {"empty", 1} => :empty,
    {"count", 1} => :count,
    {"distinct-values", 1} => :distinct_values,
    {"string", 1} => :string_,
    {"normalize-space", 1} => :normalize_space,
    {"string-length", 1} => :string_length,
    {"upper-case", 1} => :upper_case,
    {"lower-case", 1} => :lower_case,
    {"contains", 2} => :contains,
    {"starts-with", 2} => :starts_with,
    {"ends-with", 2} => :ends_with,
    {"substring", 2} => :substring,
    {"substring", 3} => :substring,
    {"substring-before", 2} => :substring_before,
    {"substring-after", 2} => :substring_after,
    {"translate", 3} => :translate,
    {"matches", 2} => :matches,
    {"matches", 3} => :matches,
    {"tokenize", 2} => :tokenize,
    {"tokenize", 3} => :tokenize,
    {"replace", 3} => :replace,
    {"replace", 4} => :replace,
    {"string-join", 2} => :string_join,
    {"number", 1} => :number,
    {"sum", 1} => :sum,
    {"round", 1} => :round_,
    {"abs", 1} => :abs_,
    {"floor", 1} => :floor,
    {"ceiling", 1} => :ceiling,
    {"name", 1} => :name_,
    {"local-name", 1} => :local_name
  }

  defp builtin!("true", [], _env), do: [true]
  defp builtin!("false", [], _env), do: [false]

  defp builtin!("concat", args, _env) when length(args) >= 2 do
    quote do: F.concat(doc, [unquote_splicing(args)])
  end

  defp builtin!("position", [], env) do
    env.position || raise Error, message: "position() outside a predicate in #{env.where}"
    quote do: [unquote(env.position)]
  end

  defp builtin!("last", [], env) do
    env.size || raise Error, message: "last() outside a predicate in #{env.where}"
    quote do: [unquote(env.size)]
  end

  defp builtin!(local, args, env) do
    case Map.fetch(@simple_builtins, {local, length(args)}) do
      {:ok, fun} -> quote do: F.unquote(fun)(doc, unquote_splicing(args))
      :error -> raise Error, message: "unsupported function #{local}/#{length(args)} in #{env.where}"
    end
  end

  # ---------------------------------------------------------------- helpers

  defp ctx!(%Env{ctx: nil, where: where}), do: raise(Error, message: "context item used where none is defined, in #{where}")
  defp ctx!(%Env{ctx: ctx}), do: ctx

  defp put_var(env, name, ast), do: %{env | vars: Map.put(env.vars, name, ast)}

  defp let_var(name), do: Macro.var(var_key(name), __MODULE__)

  defp var_key({nil, local}), do: :"v_#{sanitize(local)}"
  defp var_key({prefix, local}), do: :"v_#{sanitize("#{prefix}_#{local}")}"

  defp format_name({nil, local}), do: local
  defp format_name({prefix, local}), do: "#{prefix}:#{local}"

  defp sanitize(string) do
    string |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_") |> String.trim("_")
  end
end
