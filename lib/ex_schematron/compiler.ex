defmodule ExSchematron.Compiler do
  @moduledoc """
  Compiles a parsed schematron into the body of an Elixir validation module,
  as a quoted AST ready to be injected (`use ExSchematron` / `Module.create/3`).

  The compiled module transcribes the schematron; XPath expressions are
  compiled by `ExSchematron.XPath.Compiler` and all XPath semantics live in
  `ExSchematron.Runtime`. This module owns what is Schematron- or
  XSLT-specific: patterns, rules and checks, match-pattern contexts,
  `xsl:function` definitions, and the `document()` code-list lookup. It
  extends the XPath compiler through its `Env` hooks. Compilation raises on
  any XPath construct, function or schematron form outside the supported
  table — never a silent skip.
  """

  alias ExSchematron.Sch
  alias ExSchematron.Sch.Scopes
  alias ExSchematron.XPath.Compiler, as: XPC

  # Quoting is alias-hygienic: XP./Xml. calls inside the quotes below expand
  # to their full module names in the emitted AST.
  alias ExSchematron.Runtime, as: XP
  alias ExSchematron.Xml

  defmodule Error do
    defexception [:message]
  end

  # The variable the XPath compiler's emitted code reads the document from;
  # every generated function binds it in its head.
  @doc_var XPC.doc_var()

  @doc "Compiles a parsed schematron into a quoted module body defining `validate/1`."
  @spec build_body!(Sch.Schema.t()) :: Macro.t()
  def build_body!(%Sch.Schema{} = schema) do
    # Without defaultPhase the ISO default phase is #ALL: every pattern is active
    # and the phase declarations are inert, so they can be ignored safely.
    if schema.default_phase do
      raise Error, message: "schematron defaultPhase is not supported yet"
    end

    functions = Map.new(schema.functions, fn function -> {function.name, length(function.params)} end)

    base_env = %XPC.Env{
      ns: schema.namespaces,
      rewrite: fn ast, env -> codelist_rewrite(ast, env, schema.base_dir) end,
      resolve_call: fn name, compiled_args, env -> resolve_function_call(name, compiled_args, env, functions) end
    }

    # Scoping (collision, shadowing, hoisting) is decided by Scopes; the
    # compiler only transcribes its storage plan.
    scopes = Scopes.resolve!(schema)

    function_defs = Enum.map(schema.functions, &compile_function(&1, base_env))
    globals_def = compile_globals(scopes.globals, base_env)

    Process.delete({__MODULE__, :codelist_registry})

    {pattern_defs, pattern_calls} =
      schema.patterns
      |> Enum.zip(scopes.patterns)
      |> Enum.with_index()
      |> Enum.map(fn {{pattern, pattern_scope}, index} -> compile_pattern(pattern, index, base_env, pattern_scope) end)
      |> Enum.unzip()

    codelist_definitions = codelist_defs()

    quote do
      @doc "Validates an XML binary (or parsed document). Returns every violation."
      def validate(xml) when is_binary(xml), do: validate(Xml.parse!(xml))

      def validate(%Xml.Document{} = unquote(@doc_var)) do
        globals = globals(unquote(@doc_var))
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
  rescue
    # One public error type for generation failures, whichever layer raised.
    error in [XPC.Error] -> raise Error, message: Exception.message(error)
  end

  # ---------------------------------------------------------------- globals

  defp compile_globals(global_entries, env) do
    ctx_var = Macro.var(:ctx, __MODULE__)

    {bindings, entries, _env} =
      Enum.reduce(global_entries, {[], [], %{env | ctx: ctx_var, where: "schema-level let"}}, fn {key, name, value},
                                                                                                 {bindings, entries, env} ->
        var = Macro.var(key, __MODULE__)
        expr = XPC.compile_source!(value, env)
        binding = quote do: unquote(var) = unquote(expr)
        {[binding | bindings], [{key, var} | entries], XPC.put_var(env, name, var)}
      end)

    map_ast = {:%{}, [], Enum.reverse(entries)}

    quote do
      defp globals(unquote(@doc_var)) do
        unquote(ctx_var) = {:node, unquote(@doc_var).root_id}
        _ = unquote(ctx_var)
        unquote_splicing(Enum.reverse(bindings))
        unquote(map_ast)
      end
    end
  end

  # ---------------------------------------------------------------- patterns

  defp compile_pattern(%Sch.Pattern{} = pattern, index, env, pattern_scope) do
    pattern_fun = :"pattern_#{index}_#{sanitize(pattern.id || "anonymous")}"

    env =
      Enum.reduce(pattern_scope.bindings, env, fn {name, key}, env ->
        XPC.put_var(env, name, quote(do: globals.unquote(Macro.var(key, __MODULE__))))
      end)

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
        {:->, [], [[rule_index], quote(do: unquote(checks_fun)(unquote(@doc_var), globals, {:node, node_id}))]}
      end)

    fallback = {:->, [], [[nil], []]}
    dispatch = {:case, [], [quote(do: Enum.find_index(rule_sets, &MapSet.member?(&1, node_id))), [do: [fallback | dispatch_clauses]]]}

    pattern_def =
      quote do
        defp unquote(pattern_fun)(unquote(@doc_var), globals) do
          rule_sets = [unquote_splicing(set_exprs)]

          Enum.flat_map(XP.matched_ids(rule_sets), fn node_id ->
            unquote(dispatch)
          end)
        end
      end

    call = quote do: unquote(pattern_fun)(unquote(@doc_var), globals)
    {[pattern_def | rule_defs], call}
  end

  # ------------------------------------------------------------------ rules

  defp compile_rule(%Sch.Rule{} = rule, fun_name, env) do
    ctx_var = Macro.var(:ctx, __MODULE__)
    env = %{env | ctx: ctx_var, where: "rule #{inspect(rule.context)}"}

    {let_bindings, env} =
      Enum.reduce(rule.lets, {[], env}, fn {name, value}, {bindings, env} ->
        var = let_var(name)
        binding = quote do: unquote(var) = unquote(XPC.compile_source!(value, env))
        {[binding | bindings], XPC.put_var(env, name, var)}
      end)

    check_exprs = Enum.map(rule.checks, &compile_check(&1, env))
    let_vars = Enum.map(rule.lets, fn {name, _value} -> let_var(name) end)

    quote do
      defp unquote(fun_name)(unquote(@doc_var), globals, {:node, ctx_id} = unquote(ctx_var)) do
        _ = {unquote(@doc_var), globals, ctx_id, unquote(ctx_var)}
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
              node: XP.node_path(unquote(@doc_var), ctx_id)
            }
          ]
      end
    end
  end

  defp compile_check(%Sch.Check{} = check, env) do
    env = %{env | where: "check #{inspect(check.id)}"}
    test_expr = XPC.compile_source!(check.test, env)

    message_segments =
      Enum.map(check.message, fn
        {:text, text} -> text
        {:value_of, select} -> quote do: XP.value_of(unquote(@doc_var), unquote(XPC.compile_source!(select, env)))
      end)

    violation =
      quote do
        %{
          type: unquote(check.type),
          rule: unquote(check.id),
          test: unquote(check.test),
          flag: unquote(check.flag),
          message: XP.message([unquote_splicing(message_segments)]),
          node: XP.node_path(unquote(@doc_var), ctx_id)
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
    ast = XPC.parse!(context_source, env)
    env = %{env | ctx: quote(do: {:node, unquote(@doc_var).root_id})}
    anchored = anchor_context(ast, env)

    try do
      compile_context_reverse(anchored, env)
    catch
      :forward_fallback ->
        quote do: XP.match_set(unquote(XPC.compile_expr(anchored, env)))
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

    quote do: XP.match_set_reverse(unquote(@doc_var), unquote(chain), unquote(absolute?))
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
        Enum.map(predicates, fn predicate -> quote do: XP.ebv(unquote(XPC.compile_expr(predicate, pred_env))) end)
      rescue
        # position()/last() or another construct only the forward path handles.
        _error in [XPC.Error] -> throw(:forward_fallback)
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
  defp resolve_optional_prefix!(prefix, env), do: XPC.resolve_prefix!(prefix, env)

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
      |> Enum.reduce(%{env | where: "function #{format_name(function.name)}"}, fn {name, var}, env -> XPC.put_var(env, name, var) end)

    {bindings, env} =
      Enum.reduce(function.bindings, {[], env}, fn {name, value}, {bindings, env} ->
        var = let_var(name)
        binding = quote do: unquote(var) = unquote(XPC.compile_source!(value, env))
        {[binding | bindings], XPC.put_var(env, name, var)}
      end)

    result = XPC.compile_source!(function.result, env)
    binding_vars = Enum.map(function.bindings, fn {name, _value} -> let_var(name) end)

    quote do
      defp unquote(function_fun_name(function.name))(unquote(@doc_var), unquote_splicing(param_vars)) do
        _ = {unquote(@doc_var), unquote_splicing(param_vars)}
        unquote_splicing(Enum.reverse(bindings))
        _ = {unquote_splicing(binding_vars)}
        unquote(result)
      end
    end
  end

  # The XPath compiler's resolve_call hook: binds calls to xsl:function
  # definitions, emitted as private functions taking `doc` first.
  defp resolve_function_call(name, compiled_args, env, functions) do
    case Map.get(functions, name) do
      nil ->
        :error

      arity when arity != length(compiled_args) ->
        raise XPC.Error, message: "#{format_name(name)}() expects #{arity} arguments, got #{length(compiled_args)} in #{env.where}"

      _arity ->
        {:ok, quote(do: unquote(function_fun_name(name))(unquote(@doc_var), unquote_splicing(compiled_args)))}
    end
  end

  defp function_fun_name({prefix, local}), do: :"fn_#{sanitize("#{prefix}_#{local}")}"

  defp capture_ast(fun_name, arity), do: Code.string_to_quoted!("&#{fun_name}/#{arity}")

  # ----------------------------------------------------------- code lists

  # The corpus uses document() in exactly one shape, a code-list membership test:
  # document('x_codedb.xml')/codedb/cl[@id=N]/enumeration[@value=$v]. The list is
  # frozen into the module as a MapSet at generation time; the emitted expression
  # keeps the EBV the node sequence would have ([] or a non-empty sequence).
  # Any other use of document() falls through to the unsupported-function raise.
  defp codelist_rewrite(
         {:path, {:expr, {:fn, {nil, "document"}, [{:lit, file}]}},
          [
            {:step, :child, {:name, nil, "codedb"}, []},
            {:step, :child, {:name, nil, "cl"},
             [{:cmp, :general, :eq, {:path, :relative, [{:step, :attribute, {:name, nil, "id"}, []}]}, {:lit, cl_id}}]},
            {:step, :child, {:name, nil, "enumeration"},
             [{:cmp, :general, :eq, {:path, :relative, [{:step, :attribute, {:name, nil, "value"}, []}]}, checked_expr}]}
          ]},
         env,
         base_dir
       )
       when is_binary(file) and is_integer(cl_id) do
    # The same code list is referenced by many checks; one shared private
    # function per list keeps the module AST small.
    fun_name = register_codelist!(file, cl_id, env, base_dir)
    {:ok, quote(do: XP.codelist_member?(unquote(@doc_var), unquote(fun_name)(), unquote(XPC.compile_expr(checked_expr, env))))}
  end

  defp codelist_rewrite(_ast, _env, _base_dir), do: :pass

  # Compilation-scoped registry of the code lists referenced so far, so each is
  # emitted once as a private function definition.
  defp register_codelist!(file, cl_id, env, base_dir) do
    key = {__MODULE__, :codelist_registry}
    registry = Process.get(key, %{})

    case Map.fetch(registry, {file, cl_id}) do
      {:ok, {fun_name, _values}} ->
        fun_name

      :error ->
        values = codelist_values!(file, cl_id, env, base_dir)
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

  defp codelist_values!(file, cl_id, env, base_dir) do
    unless base_dir do
      raise Error, message: "document(#{inspect(file)}) needs the schematron's directory; compile from a file path, in #{env.where}"
    end

    path = Path.join(base_dir, file)
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

  # ---------------------------------------------------------------- helpers

  defp let_var(name), do: Macro.var(Scopes.var_key(name), __MODULE__)

  defp format_name({nil, local}), do: local
  defp format_name({prefix, local}), do: "#{prefix}:#{local}"

  defp sanitize(string) do
    string |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_") |> String.trim("_")
  end
end
