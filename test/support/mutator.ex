defmodule ExSchematron.Mutator do
  @moduledoc """
  Deterministic XML mutations for differential testing against a reference
  Schematron implementation (Saxon + the schematron's XSLT).

  Three families, one mutant per site: text content replaced (`@@@`, or a wrong
  number when the original is numeric), attribute value replaced (xmlns/xsi
  excluded), leaf element removed. Working on the raw binary keeps mutant names
  stable, so verdicts can be frozen in a manifest and replayed without Java.
  """

  @type mutant :: {name :: binary(), xml :: binary()}

  @spec mutants(binary(), binary()) :: [mutant()]
  def mutants(source, base_name) do
    base = String.replace(base_name, ~r/[^A-Za-z0-9_-]/, "")

    named(base, "text", text_mutations(source)) ++
      named(base, "attr", attribute_mutations(source)) ++
      named(base, "del", deletion_mutations(source))
  end

  defp named(base, kind, mutations) do
    mutations
    |> Enum.with_index()
    |> Enum.map(fn {mutated, index} -> {"#{base}__#{kind}_#{index}", mutated} end)
  end

  defp text_mutations(source) do
    ~r/>([^<>]+)</
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [_full, {start, len}] -> {start, len} end)
    |> Enum.filter(fn {start, len} -> String.trim(binary_part(source, start, len)) != "" end)
    |> Enum.map(fn {start, len} ->
      original = String.trim(binary_part(source, start, len))

      # Typed reference implementations cast some values (xs:boolean, numerics)
      # while evaluating; the replacement must stay castable or Saxon aborts
      # instead of producing a comparable verdict.
      replacement =
        cond do
          original == "true" -> "false"
          original == "false" -> "true"
          String.match?(original, ~r/^\d{4}-\d{2}-\d{2}/) -> "2099-12-31"
          String.match?(original, ~r/^-?\d+(\.\d+)?$/) -> "99999.99"
          true -> "@@@"
        end

      replace_range(source, {start, len}, replacement)
    end)
  end

  defp attribute_mutations(source) do
    declaration_end =
      case :binary.match(source, "?>") do
        {position, length} -> position + length
        :nomatch -> 0
      end

    ~r/([\w:.-]+)="([^"]*)"/
    |> Regex.scan(source, return: :index)
    |> Enum.reject(fn [{full_start, _full_len}, {name_start, name_len}, _value] ->
      full_start < declaration_end or binary_part(source, name_start, name_len) =~ ~r/^(xmlns|xsi:|xml:)/
    end)
    |> Enum.map(fn [_full, _name, {start, len}] -> replace_range(source, {start, len}, "@@@") end)
  end

  defp deletion_mutations(source) do
    ~r|<([\w:.-]+)(\s[^<>]*)?>[^<>]*</([\w:.-]+)>|
    |> Regex.scan(source, return: :index)
    |> Enum.filter(fn [_full, {open_start, open_len}, _attrs, {close_start, close_len}] ->
      binary_part(source, open_start, open_len) == binary_part(source, close_start, close_len)
    end)
    |> Enum.map(fn [{start, len} | _groups] -> replace_range(source, {start, len}, "") end)
  end

  defp replace_range(source, {start, len}, replacement) do
    prefix = binary_part(source, 0, start)
    suffix = binary_part(source, start + len, byte_size(source) - start - len)
    prefix <> replacement <> suffix
  end
end
