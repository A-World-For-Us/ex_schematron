defmodule ExSchematron.Sch.Scopes do
  @moduledoc """
  Resolves every variable declaration of a parsed schematron into storage
  bindings. The scoping rules live here; the compiler only transcribes the
  resulting plan:

    * A variable multiply defined in one scope is an error (ISO 2016 section
      5.4.5 clause 3); shadowing a let of an outer scope stays legal (the
      conformance corpus' `let-scope-*` testcases require it).
    * Pattern lets are hoisted to schema level, like SchXslt compiles them
      (global xsl:variable): the corpus references them across pattern
      boundaries. One that shadows a schema-level let keeps a separate storage
      key, so the schema value stays visible outside the declaring pattern.
    * Storage keys are sanitized Elixir atoms, so two distinct names that
      sanitize to the same key are an error -- stored together they would
      silently overwrite each other in the generated module.

  `resolve!/1` returns the storage plan: the global entries in evaluation
  order, and one name-to-key binding map per pattern.
  """

  alias ExSchematron.Sch

  defstruct globals: [], patterns: []

  @type var_name :: {prefix :: String.t() | nil, local :: String.t()}
  @type t :: %__MODULE__{
          globals: [{key :: atom(), var_name(), value :: String.t()}],
          patterns: [%{bindings: %{var_name() => atom()}}]
        }

  @spec resolve!(Sch.Schema.t()) :: t()
  def resolve!(%Sch.Schema{} = schema) do
    Enum.each(schema.patterns, fn pattern ->
      Enum.each(pattern.rules, fn rule ->
        check_scope!(Enum.map(rule.lets, &elem(&1, 0)), "rule #{inspect(rule.context)}")
      end)
    end)

    Enum.each(schema.functions, fn function ->
      names = function.params ++ Enum.map(function.bindings, &elem(&1, 0))
      check_scope!(names, "function #{format_name(function.name)}")
    end)

    check_scope!(Enum.map(schema.lets, &elem(&1, 0)), "schema")

    Enum.each(schema.patterns, fn pattern ->
      check_scope!(Enum.map(pattern.lets, &elem(&1, 0)), "pattern #{inspect(pattern.id)}")
    end)

    schema_names = MapSet.new(schema.lets, fn {name, _value} -> name end)

    globals =
      Enum.map(schema.lets, fn {name, value} -> {var_key(name), name, value} end) ++
        Enum.map(hoist_pattern_lets(schema.patterns), fn {name, value} ->
          {storage_key(name, schema_names), name, value}
        end)

    check_global_keys!(globals)

    # Schema entries come first, so a shadowed name maps to the schema key by
    # default; the declaring pattern overrides it below.
    base = Enum.reduce(globals, %{}, fn {key, name, _value}, acc -> Map.put_new(acc, name, key) end)

    patterns =
      Enum.map(schema.patterns, fn pattern ->
        bindings =
          Enum.reduce(pattern.lets, base, fn {name, _value}, acc ->
            Map.put(acc, name, storage_key(name, schema_names))
          end)

        %{bindings: bindings}
      end)

    %__MODULE__{globals: globals, patterns: patterns}
  end

  @doc "Storage key of a variable name: a sanitized `:v_`-prefixed atom."
  @spec var_key(var_name()) :: atom()
  def var_key({nil, local}), do: :"v_#{sanitize(local)}"
  def var_key({prefix, local}), do: :"v_#{sanitize("#{prefix}_#{local}")}"

  defp storage_key(name, schema_names) do
    if MapSet.member?(schema_names, name), do: :"#{var_key(name)}__pattern", else: var_key(name)
  end

  defp check_scope!(names, where) do
    names
    |> Enum.frequencies()
    |> Enum.each(fn {name, count} ->
      if count > 1 do
        raise Sch.Error, message: "variable $#{format_name(name)} multiply defined in #{where}"
      end
    end)

    names |> Enum.uniq() |> Enum.group_by(&var_key/1) |> Enum.each(&check_key_group!(&1, where))
  end

  defp check_global_keys!(globals) do
    globals
    |> Enum.group_by(fn {key, _name, _value} -> key end, fn {_key, name, _value} -> name end)
    |> Enum.each(fn {key, names} -> check_key_group!({key, Enum.uniq(names)}, "the schema globals") end)
  end

  defp check_key_group!({_key, [_single]}, _where), do: :ok

  defp check_key_group!({key, names}, where) do
    pretty = names |> Enum.map(&"$#{format_name(&1)}") |> Enum.sort() |> Enum.join(" and ")
    raise Sch.Error, message: "variables #{pretty} collide on storage key #{inspect(key)} in #{where}"
  end

  defp hoist_pattern_lets(patterns) do
    all_lets = for pattern <- patterns, let <- pattern.lets, do: {let, pattern.id}

    all_lets
    |> Enum.group_by(fn {{name, _value}, _pattern_id} -> name end)
    |> Enum.each(fn {name, declarations} ->
      values = declarations |> Enum.map(fn {{_name, value}, _pattern_id} -> value end) |> Enum.uniq()

      if length(values) > 1 do
        pattern_ids = Enum.map(declarations, &elem(&1, 1))

        raise Sch.Error,
          message: "pattern let $#{format_name(name)} declared with different values in patterns #{inspect(pattern_ids)}"
      end
    end)

    all_lets |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(fn {name, _value} -> name end)
  end

  defp format_name({nil, local}), do: local
  defp format_name({prefix, local}), do: "#{prefix}:#{local}"

  defp sanitize(string) do
    string |> String.downcase() |> String.replace(~r/[^a-z0-9_]+/, "_") |> String.trim("_")
  end
end
