defmodule ExSchematron.Runtime.Functions do
  @moduledoc """
  XPath function library for generated modules.

  Every function takes the document first, then its arguments as sequences, and
  returns a sequence. Optional `xs:string?` parameters follow the spec rule:
  the empty sequence is interpreted as the zero-length string.
  """

  alias ExSchematron.Runtime
  alias ExSchematron.Runtime.Error
  alias ExSchematron.Xml

  # ------------------------------------------------------------ boolean

  def not_(_doc, seq), do: [not Runtime.ebv(seq)]
  def boolean_(_doc, seq), do: [Runtime.ebv(seq)]
  def exists(_doc, seq), do: [seq != []]
  def empty(_doc, seq), do: [seq == []]

  # ----------------------------------------------------------- sequence

  def count(_doc, seq), do: [length(seq)]

  def distinct_values(doc, seq) do
    doc
    |> Runtime.atomize(seq)
    |> Enum.uniq_by(&distinct_key/1)
  end

  defp distinct_key({:untyped, string}), do: {:string, string}
  defp distinct_key(string) when is_binary(string), do: {:string, string}
  defp distinct_key(int) when is_integer(int), do: {:number, Decimal.new(int) |> Decimal.normalize()}
  defp distinct_key(%Decimal{} = decimal), do: {:number, Decimal.normalize(decimal)}
  defp distinct_key(float) when is_float(float), do: {:number, float |> Decimal.from_float() |> Decimal.normalize()}
  defp distinct_key(other), do: other

  # ------------------------------------------------------------- string

  def string_(doc, seq), do: [one_string!(doc, seq)]

  def normalize_space(doc, seq) do
    normalized = doc |> one_string!(seq) |> String.split([" ", "\t", "\n", "\r"], trim: true) |> Enum.join(" ")
    [normalized]
  end

  # XPath string lengths and positions count codepoints, not grapheme clusters.
  def string_length(doc, seq), do: [length(String.to_charlist(one_string!(doc, seq)))]

  def upper_case(doc, seq), do: [doc |> one_string!(seq) |> String.upcase()]
  def lower_case(doc, seq), do: [doc |> one_string!(seq) |> String.downcase()]

  def contains(doc, haystack, needle), do: [String.contains?(one_string!(doc, haystack), one_string!(doc, needle))]
  def starts_with(doc, haystack, needle), do: [String.starts_with?(one_string!(doc, haystack), one_string!(doc, needle))]
  def ends_with(doc, haystack, needle), do: [String.ends_with?(one_string!(doc, haystack), one_string!(doc, needle))]

  def concat(doc, args), do: [args |> Enum.map(&one_string!(doc, &1)) |> IO.iodata_to_binary()]

  def string_join(doc, seq, separator) do
    joined =
      doc
      |> Runtime.atomize(seq)
      |> Enum.map(&Runtime.item_string(doc, &1))
      |> Enum.join(one_string!(doc, separator))

    [joined]
  end

  def substring(doc, input, start) do
    string = one_string!(doc, input)
    start_pos = rounded_number!(doc, start)
    [do_substring(string, start_pos, :infinity)]
  end

  def substring(doc, input, start, len) do
    string = one_string!(doc, input)
    start_pos = rounded_number!(doc, start)
    length_val = rounded_number!(doc, len)
    [do_substring(string, start_pos, length_val)]
  end

  # Characters (codepoints) at 1-based positions p with p >= start and (if
  # bounded) p < start + len. Infinite bounds get explicit clauses: Erlang term
  # order puts every integer below any atom, so `position >= :neg_infinity`
  # would be false, not true. `:infinity` as len is the 2-arg unbounded
  # sentinel; with a -INF start every position satisfies p >= start.
  defp do_substring(_string, :nan, _len), do: ""
  defp do_substring(_string, _start, :nan), do: ""
  defp do_substring(string, :neg_infinity, :infinity), do: string
  defp do_substring(_string, :neg_infinity, _len), do: ""
  defp do_substring(_string, :infinity, _len), do: ""

  defp do_substring(string, start, len) do
    string
    |> String.to_charlist()
    |> Enum.with_index(1)
    |> Enum.filter(fn {_codepoint, position} ->
      position >= start and (len == :infinity or position < start + len)
    end)
    |> Enum.map(&elem(&1, 0))
    |> List.to_string()
  end

  def substring_before(doc, input, marker) do
    string = one_string!(doc, input)
    marker_string = one_string!(doc, marker)

    case marker_string != "" && String.split(string, marker_string, parts: 2) do
      [before, _after] -> [before]
      _no_match -> [""]
    end
  end

  def substring_after(doc, input, marker) do
    string = one_string!(doc, input)
    marker_string = one_string!(doc, marker)

    case marker_string != "" && String.split(string, marker_string, parts: 2) do
      [_before, rest] -> [rest]
      _no_match -> [""]
    end
  end

  def translate(doc, input, from, to) do
    string = one_string!(doc, input)
    from_chars = doc |> one_string!(from) |> String.graphemes()
    to_chars = doc |> one_string!(to) |> String.graphemes()
    # Reversed before Map.new so that for a character repeated in `from` the
    # first occurrence's replacement wins, as fn:translate specifies.
    mapping = from_chars |> Enum.zip(Stream.concat(to_chars, Stream.repeatedly(fn -> nil end))) |> Enum.reverse() |> Map.new()

    translated =
      string
      |> String.graphemes()
      |> Enum.map_join(fn grapheme ->
        case Map.fetch(mapping, grapheme) do
          {:ok, nil} -> ""
          {:ok, replacement} -> replacement
          :error -> grapheme
        end
      end)

    [translated]
  end

  # -------------------------------------------------------------- regex

  def matches(doc, input, pattern), do: matches(doc, input, pattern, [""])

  def matches(doc, input, pattern, flags) do
    regex = compile_pattern!(one_string!(doc, pattern), one_string!(doc, flags))
    [Regex.match?(regex, one_string!(doc, input))]
  end

  def tokenize(doc, input, pattern), do: tokenize(doc, input, pattern, [""])

  def tokenize(doc, input, pattern, flags) do
    regex = compile_pattern!(one_string!(doc, pattern), one_string!(doc, flags))

    case one_string!(doc, input) do
      "" -> []
      string -> String.split(string, regex)
    end
  end

  def replace(doc, input, pattern, replacement), do: replace(doc, input, pattern, replacement, [""])

  def replace(doc, input, pattern, replacement, flags) do
    regex = compile_pattern!(one_string!(doc, pattern), one_string!(doc, flags))
    elixir_replacement = doc |> one_string!(replacement) |> convert_replacement()
    [Regex.replace(regex, one_string!(doc, input), elixir_replacement)]
  end

  # XPath group references are $1..$9; Elixir uses \g{1}.
  defp convert_replacement(replacement) do
    replacement
    |> String.replace("\\$", "\x00")
    |> then(fn escaped -> Regex.replace(~r/\$(\d)/, escaped, fn _match, digit -> "\\g{#{digit}}" end) end)
    |> String.replace("\x00", "$")
  end

  @doc """
  Compiles an XSD/XPath regex with Elixir's PCRE engine. The dialects agree on
  everything the corpus uses; constructs whose meaning would silently differ
  (character class subtraction, `\\i`/`\\c` classes) are rejected.
  """
  def compile_pattern!(pattern, flags) do
    if String.contains?(pattern, "-[") do
      raise Error, message: "XSD character class subtraction is not supported: #{inspect(pattern)}"
    end

    if String.match?(pattern, ~r/\\[icIC]/) do
      raise Error, message: "XSD \\i and \\c character classes are not supported: #{inspect(pattern)}"
    end

    case Regex.compile(pattern, "u" <> flags) do
      {:ok, regex} -> regex
      {:error, {reason, at}} -> raise Error, message: "invalid regular expression #{inspect(pattern)}: #{reason} (at #{at})"
    end
  end

  # ------------------------------------------------------------- number

  def number(doc, seq) do
    case Runtime.atomize(doc, seq) do
      [] -> [:nan]
      [item] -> [to_double(item)]
      _multiple -> raise Error, message: "fn:number on a sequence of several items"
    end
  end

  defp to_double({:untyped, string}), do: Runtime.parse_double(string)
  defp to_double(string) when is_binary(string), do: Runtime.parse_double(string)
  defp to_double(number) when is_number(number), do: Runtime.to_float(number)
  defp to_double(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_double(true), do: 1.0
  defp to_double(false), do: 0.0
  defp to_double(special) when special in [:nan, :infinity, :neg_infinity], do: special
  defp to_double(_other), do: :nan

  def sum(doc, seq) do
    total =
      doc
      |> Runtime.atomize(seq)
      |> Enum.map(&sum_operand/1)
      |> Enum.reduce(0, fn item, acc -> add(acc, item) end)

    [total]
  end

  defp sum_operand({:untyped, string}), do: Runtime.parse_double(string)
  defp sum_operand(number) when is_number(number), do: number
  defp sum_operand(%Decimal{} = decimal), do: decimal
  defp sum_operand(special) when special in [:nan, :infinity, :neg_infinity], do: special
  defp sum_operand(other), do: raise(Error, message: "fn:sum on non-numeric #{inspect(other)}")

  defp add(:nan, _right), do: :nan
  defp add(_left, :nan), do: :nan
  defp add(left, right) when is_atom(left) or is_atom(right), do: if(is_atom(left), do: left, else: right)
  defp add(left, right) when is_float(left) or is_float(right), do: Runtime.to_float(left) + Runtime.to_float(right)
  defp add(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp add(left, right), do: Decimal.add(Runtime.to_decimal(left), Runtime.to_decimal(right))

  def round_(doc, seq) do
    case number_operand(doc, seq) do
      [] -> []
      [int] when is_integer(int) -> [int]
      [special] when is_atom(special) -> [special]
      # XPath round: half towards positive infinity, so round(x) = floor(x + 0.5).
      [float] when is_float(float) -> [:math.floor(float + 0.5)]
      [%Decimal{} = decimal] -> [decimal |> Decimal.add(Decimal.new("0.5")) |> Decimal.round(0, :floor)]
    end
  end

  def abs_(doc, seq) do
    case number_operand(doc, seq) do
      [] -> []
      [int] when is_integer(int) -> [Kernel.abs(int)]
      [float] when is_float(float) -> [Kernel.abs(float)]
      [%Decimal{} = decimal] -> [Decimal.abs(decimal)]
      [:nan] -> [:nan]
      [_infinite] -> [:infinity]
    end
  end

  def floor(doc, seq) do
    case number_operand(doc, seq) do
      [] -> []
      [int] when is_integer(int) -> [int]
      [float] when is_float(float) -> [:math.floor(float)]
      [%Decimal{} = decimal] -> [Decimal.round(decimal, 0, :floor)]
      [special] -> [special]
    end
  end

  def ceiling(doc, seq) do
    case number_operand(doc, seq) do
      [] -> []
      [int] when is_integer(int) -> [int]
      [float] when is_float(float) -> [:math.ceil(float)]
      [%Decimal{} = decimal] -> [Decimal.round(decimal, 0, :ceiling)]
      [special] -> [special]
    end
  end

  defp number_operand(doc, seq) do
    case Runtime.atomize(doc, seq) do
      [] -> []
      [{:untyped, string}] -> [Runtime.parse_double(string)]
      [number] when is_number(number) or is_atom(number) -> [number]
      [%Decimal{} = decimal] -> [decimal]
      other -> raise Error, message: "numeric function on #{inspect(other)}"
    end
  end

  defp rounded_number!(doc, seq) do
    case number(doc, seq) do
      [:nan] -> :nan
      [special] when is_atom(special) -> special
      [float] -> trunc(:math.floor(float + 0.5))
    end
  end

  # --------------------------------------------------------------- node

  def name_(doc, seq) do
    case seq do
      [] ->
        [""]

      [{:node, id}] ->
        node = Xml.node(doc, id)

        case {node.prefix, node.name} do
          {_prefix, nil} -> [""]
          {nil, {_uri, local}} -> [local]
          {prefix, {_uri, local}} -> [prefix <> ":" <> local]
        end

      _other ->
        raise Error, message: "fn:name expects a single node"
    end
  end

  def local_name(doc, seq) do
    case seq do
      [] -> [""]
      [{:node, id}] -> [local_name_of(Xml.node(doc, id))]
      _other -> raise Error, message: "fn:local-name expects a single node"
    end
  end

  defp local_name_of(%Xml.Node{name: nil}), do: ""
  defp local_name_of(%Xml.Node{name: {_uri, local}}), do: local

  # ------------------------------------------------------------- helpers

  # xs:string? parameter: empty sequence means the zero-length string.
  defp one_string!(_doc, []), do: ""
  defp one_string!(doc, [item]), do: Runtime.item_string(doc, item)
  defp one_string!(_doc, _seq), do: raise(Error, message: "expected a single string")
end
