defmodule ExSchematron.XPath.Compiler do
  @moduledoc """
  Compiles an XPath source string (or parsed AST) into a quoted Elixir
  expression that evaluates it through `ExSchematron.Runtime`. Compilation
  raises on any construct or function outside the supported table — never a
  silent skip.

  The emitted code reads the `ExSchematron.Xml.Document` from the variable
  `doc_var/0` returns, which the caller must bind around any spliced
  expression; the context item, `position()` and `last()` are quoted
  variables carried by the `Env`. Callers extend the engine through two
  `Env` hooks:

    * `rewrite` — `fn ast, env -> {:ok, quoted} | :pass end`, consulted for
      every (sub)expression before the built-in clauses. This is how a caller
      supports special expression shapes (`ExSchematron`'s `document()`
      code-list lookup, for example).
    * `resolve_call` — `fn name, compiled_args, env -> {:ok, quoted} | :error end`,
      consulted for function calls that are neither `fn:` builtins nor `xs:`
      constructors. This is how a caller binds user-defined functions.
  """

  alias ExSchematron.XPath.Parser

  # Quoting is alias-hygienic: XP./F. calls inside the quotes below expand to
  # their full module names in the emitted AST.
  alias ExSchematron.Runtime, as: XP
  alias ExSchematron.Runtime.Functions, as: F

  defmodule Error do
    defexception [:message]
  end

  defmodule Env do
    @moduledoc """
    Compilation environment: `ns` maps prefixes to URIs, `vars` maps
    `{prefix, local}` variable names to the quoted expression yielding their
    value, `ctx`/`position`/`size` are the quoted variables of the dynamic
    context, `where` is a location string for error messages, and
    `rewrite`/`resolve_call` are the extension hooks described in
    `ExSchematron.XPath.Compiler`.
    """
    defstruct ns: %{},
              vars: %{},
              ctx: nil,
              position: nil,
              size: nil,
              where: nil,
              rewrite: nil,
              resolve_call: nil
  end

  @doc """
  The quoted variable through which emitted code reads the document. Hygiene
  scopes it to this module, so callers bind it with `unquote(doc_var())` in a
  function head or an assignment, never as a bare `doc`.
  """
  @spec doc_var() :: Macro.t()
  def doc_var, do: Macro.var(:doc, __MODULE__)

  @doc "Parses an XPath source, contextualizing errors with `env.where`."
  @spec parse!(binary(), Env.t()) :: term()
  def parse!(source, env) do
    Parser.parse!(source)
  rescue
    error ->
      raise Error, message: "cannot parse #{inspect(source)} in #{env.where}: #{Exception.message(error)}"
  end

  @doc "Parses and compiles an XPath source into a quoted expression."
  @spec compile_source!(binary(), Env.t()) :: Macro.t()
  def compile_source!(source, env), do: source |> parse!(env) |> compile_expr(env)

  @doc "Binds variable `name` to the quoted expression `ast` in the environment."
  @spec put_var(Env.t(), {binary() | nil, binary()}, Macro.t()) :: Env.t()
  def put_var(env, name, ast), do: %{env | vars: Map.put(env.vars, name, ast)}

  @doc "Compiles a parsed XPath AST into a quoted expression."
  @spec compile_expr(term(), Env.t()) :: Macro.t()
  def compile_expr(ast, %Env{rewrite: rewrite} = env) when rewrite != nil do
    case rewrite.(ast, env) do
      {:ok, quoted} -> quoted
      :pass -> do_compile_expr(ast, env)
    end
  end

  def compile_expr(ast, env), do: do_compile_expr(ast, env)

  defp do_compile_expr({:lit, value}, _env) when is_binary(value) or is_integer(value), do: [value]
  defp do_compile_expr({:lit, %Decimal{} = decimal}, _env), do: quote(do: [Decimal.new(unquote(Decimal.to_string(decimal)))])

  defp do_compile_expr({:seq, exprs}, env) do
    compiled = Enum.map(exprs, &compile_expr(&1, env))
    quote do: Enum.concat([unquote_splicing(compiled)])
  end

  defp do_compile_expr({:or, left, right}, env) do
    quote do: [XP.ebv(unquote(compile_expr(left, env))) or XP.ebv(unquote(compile_expr(right, env)))]
  end

  defp do_compile_expr({:and, left, right}, env) do
    quote do: [XP.ebv(unquote(compile_expr(left, env))) and XP.ebv(unquote(compile_expr(right, env)))]
  end

  defp do_compile_expr({:cmp, :general, op, left, right}, env) do
    quote do: XP.general_cmp(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:cmp, :value, op, left, right}, env) do
    quote do: XP.value_cmp(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:cmp, :node, op, left, right}, env) do
    quote do: XP.node_cmp(unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:arith, op, left, right}, env) do
    quote do: XP.arith(doc, unquote(op), unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:unary_minus, expr}, env) do
    quote do: XP.unary_minus(doc, unquote(compile_expr(expr, env)))
  end

  defp do_compile_expr({:union, left, right}, env) do
    quote do: XP.union(unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:range, left, right}, env) do
    quote do: XP.range(unquote(compile_expr(left, env)), unquote(compile_expr(right, env)))
  end

  defp do_compile_expr({:concat_op, left, right}, env) do
    quote do: F.concat(doc, [unquote(compile_expr(left, env)), unquote(compile_expr(right, env))])
  end

  defp do_compile_expr({:if, condition, then_expr, else_expr}, env) do
    quote do
      if XP.ebv(unquote(compile_expr(condition, env))) do
        unquote(compile_expr(then_expr, env))
      else
        unquote(compile_expr(else_expr, env))
      end
    end
  end

  defp do_compile_expr({:for, bindings, body}, env), do: compile_for(bindings, body, env)

  defp do_compile_expr({:quant, kind, bindings, satisfies}, env) do
    quote do: [unquote(compile_quant(kind, bindings, satisfies, env))]
  end

  defp do_compile_expr({:cast, expr, type, allow_empty?}, env) do
    validate_cast_type!(type, env)
    quote do: XP.cast(doc, unquote(compile_expr(expr, env)), unquote(type), unquote(allow_empty?))
  end

  defp do_compile_expr({:castable, expr, type, allow_empty?}, env) do
    validate_cast_type!(type, env)
    quote do: XP.castable?(doc, unquote(compile_expr(expr, env)), unquote(type), unquote(allow_empty?))
  end

  defp do_compile_expr({:var, name}, env) do
    case Map.fetch(env.vars, name) do
      {:ok, var_ast} -> var_ast
      :error -> raise Error, message: "unknown variable $#{format_name(name)} in #{env.where}"
    end
  end

  defp do_compile_expr(:context_item, env), do: quote(do: [unquote(ctx!(env))])

  defp do_compile_expr({:path, origin, steps}, env) do
    initial =
      case origin do
        :root -> quote do: XP.root(doc)
        :relative -> quote do: [unquote(ctx!(env))]
        {:expr, expr} -> compile_expr(expr, env)
      end

    Enum.reduce(steps, initial, fn step, acc -> compile_step(step, acc, env) end)
  end

  defp do_compile_expr({:filter, primary, predicates}, env) do
    quote do: XP.filter(doc, unquote(compile_expr(primary, env)), unquote(compile_predicates(predicates, env)))
  end

  defp do_compile_expr({:fn, name, args}, env), do: compile_call(name, args, env)

  defp do_compile_expr(other, env) do
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

  @doc "Resolves a namespace prefix through `env.ns`, raising on an undeclared one."
  @spec resolve_prefix!(binary(), Env.t()) :: binary()
  def resolve_prefix!(prefix, env) do
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
    compiled = Enum.map(args, &compile_expr(&1, env))

    case env.resolve_call && env.resolve_call.(name, compiled, env) do
      {:ok, quoted} -> quoted
      _unresolved -> raise Error, message: "unknown function #{format_name(name)}() in #{env.where}"
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

  @doc "Formats a `{prefix, local}` name for error messages."
  def format_name({nil, local}), do: local
  def format_name({prefix, local}), do: "#{prefix}:#{local}"

  defp sanitize(string) do
    string |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_") |> String.trim("_")
  end
end
