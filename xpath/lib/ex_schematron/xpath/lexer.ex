defmodule ExSchematron.XPath.Lexer do
  @moduledoc """
  Tokenizer for the XPath subset used by the supported schematrons.

  Emits `{tag, value, offset}` tuples. Names are emitted as `{:qname, prefix, local}`
  values; keyword disambiguation (`and`, `div`, `if`, ...) is the parser's job, as
  XPath keywords are not reserved words.
  """

  defmodule Error do
    defexception [:message]
  end

  @type token :: {atom(), term(), non_neg_integer()}

  @two_char_symbols %{
    "//" => :double_slash,
    "::" => :axis_sep,
    ".." => :dotdot,
    "!=" => :ne,
    "<=" => :le,
    ">=" => :ge,
    "<<" => :precedes,
    ">>" => :follows,
    "||" => :concat
  }

  @one_char_symbols %{
    "(" => :lparen,
    ")" => :rparen,
    "[" => :lbracket,
    "]" => :rbracket,
    "," => :comma,
    "@" => :at,
    "/" => :slash,
    "|" => :union,
    "+" => :plus,
    "-" => :minus,
    "*" => :star,
    "=" => :eq,
    "<" => :lt,
    ">" => :gt,
    "$" => :dollar,
    "?" => :question,
    "." => :dot
  }

  @spec tokenize!(binary()) :: [token()]
  def tokenize!(input) do
    tokenize(input, 0, [])
  end

  defp tokenize(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp tokenize(<<char, rest::binary>>, offset, acc) when char in ~c[ \t\n\r] do
    tokenize(rest, offset + 1, acc)
  end

  defp tokenize(<<"(:", rest::binary>>, offset, acc) do
    {rest, consumed} = skip_comment(rest, 1, 2)
    tokenize(rest, offset + consumed, acc)
  end

  defp tokenize(<<quote_char, _rest::binary>> = input, offset, acc) when quote_char in [?', ?"] do
    {value, rest, consumed} = take_string(input, quote_char)
    tokenize(rest, offset + consumed, [{:string, value, offset} | acc])
  end

  defp tokenize(<<char, _rest::binary>> = input, offset, acc) when char in ?0..?9 do
    {token, rest, consumed} = take_number(input, offset)
    tokenize(rest, offset + consumed, [token | acc])
  end

  defp tokenize(<<".", char, _rest::binary>> = input, offset, acc) when char in ?0..?9 do
    {token, rest, consumed} = take_number(input, offset)
    tokenize(rest, offset + consumed, [token | acc])
  end

  defp tokenize(<<two::binary-size(2), rest::binary>>, offset, acc) when is_map_key(@two_char_symbols, two) do
    tokenize(rest, offset + 2, [{Map.fetch!(@two_char_symbols, two), two, offset} | acc])
  end

  defp tokenize(<<one::binary-size(1), rest::binary>>, offset, acc) when is_map_key(@one_char_symbols, one) do
    case {one, rest, acc} do
      # "*:" NCName is a local-name wildcard, but only where a name test may appear,
      # never right after an operand (there "*" is multiplication, ":" would be stray).
      {"*", <<":", name_rest::binary>>, _acc} ->
        if name_start?(name_rest) and not operand_end?(acc) do
          {local, name_rest, consumed} = take_ncname(name_rest)
          tokenize(name_rest, offset + 2 + consumed, [{:local_wildcard, local, offset} | acc])
        else
          tokenize(rest, offset + 1, [{:star, one, offset} | acc])
        end

      _other ->
        tokenize(rest, offset + 1, [{Map.fetch!(@one_char_symbols, one), one, offset} | acc])
    end
  end

  defp tokenize(input, offset, acc) do
    if name_start?(input) do
      {token, rest, consumed} = take_name(input, offset)
      tokenize(rest, offset + consumed, [token | acc])
    else
      <<char::utf8, _rest::binary>> = input
      raise Error, message: "unexpected character #{inspect(<<char::utf8>>)} at offset #{offset}"
    end
  end

  defp skip_comment(<<":)", rest::binary>>, 1, consumed), do: {rest, consumed + 2}
  defp skip_comment(<<":)", rest::binary>>, depth, consumed), do: skip_comment(rest, depth - 1, consumed + 2)
  defp skip_comment(<<"(:", rest::binary>>, depth, consumed), do: skip_comment(rest, depth + 1, consumed + 2)
  defp skip_comment(<<_char, rest::binary>>, depth, consumed), do: skip_comment(rest, depth, consumed + 1)
  defp skip_comment(<<>>, _depth, _consumed), do: raise(Error, message: "unterminated comment")

  defp take_string(<<quote_char, rest::binary>>, quote_char) do
    take_string_content(rest, quote_char, [], 1)
  end

  defp take_string_content(<<quote_char, quote_char, rest::binary>>, quote_char, parts, consumed) do
    take_string_content(rest, quote_char, [<<quote_char>> | parts], consumed + 2)
  end

  defp take_string_content(<<quote_char, rest::binary>>, quote_char, parts, consumed) do
    {parts |> Enum.reverse() |> IO.iodata_to_binary(), rest, consumed + 1}
  end

  defp take_string_content(<<char::utf8, rest::binary>>, quote_char, parts, consumed) do
    take_string_content(rest, quote_char, [<<char::utf8>> | parts], consumed + byte_size(<<char::utf8>>))
  end

  defp take_string_content(<<>>, _quote_char, _parts, _consumed) do
    raise Error, message: "unterminated string literal"
  end

  defp take_number(input, offset) do
    {digits, rest} = split_while(input, fn char -> char in ?0..?9 end)

    {digits, rest} =
      case rest do
        <<".", frac_rest::binary>> ->
          {frac, frac_rest} = split_while(frac_rest, fn char -> char in ?0..?9 end)
          {digits <> "." <> frac, frac_rest}

        _no_fraction ->
          {digits, rest}
      end

    case rest do
      <<exp_char, _::binary>> when exp_char in [?e, ?E] ->
        raise Error, message: "double literals are not supported (offset #{offset})"

      _no_exponent ->
        if String.contains?(digits, ".") do
          # Decimal.new rejects ".5" and "5."; XPath allows both.
          normalized = digits |> String.replace_prefix(".", "0.") |> String.replace_suffix(".", ".0")
          {{:decimal, Decimal.new(normalized), offset}, rest, byte_size(digits)}
        else
          {{:integer, String.to_integer(digits), offset}, rest, byte_size(digits)}
        end
    end
  end

  defp take_name(input, offset) do
    {first, rest, first_len} = take_ncname(input)

    case rest do
      # "::" must stay a separate token: `child::foo`
      <<"::", _::binary>> ->
        {{:qname, {nil, first}, offset}, rest, first_len}

      <<":*", rest::binary>> ->
        {{:prefix_wildcard, first, offset}, rest, first_len + 2}

      <<":", name_rest::binary>> ->
        if name_start?(name_rest) do
          {local, name_rest, local_len} = take_ncname(name_rest)
          {{:qname, {first, local}, offset}, name_rest, first_len + 1 + local_len}
        else
          raise Error, message: "expected name after #{inspect(first <> ":")} at offset #{offset}"
        end

      _plain_name ->
        {{:qname, {nil, first}, offset}, rest, first_len}
    end
  end

  defp take_ncname(input) do
    {name, rest} = split_while(input, &ncname_char?/1)
    {name, rest, byte_size(name)}
  end

  defp name_start?(<<char::utf8, _::binary>>) do
    char in ?a..?z or char in ?A..?Z or char == ?_ or char > 127
  end

  defp name_start?(_other), do: false

  defp ncname_char?(char) do
    char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-, ?.] or char > 127
  end

  # After these tokens, "*" can only be the multiplication operator.
  defp operand_end?([{tag, _value, _offset} | _rest]) do
    tag in [:qname, :string, :integer, :decimal, :rparen, :rbracket, :dot, :dotdot, :star]
  end

  defp operand_end?([]), do: false

  defp split_while(binary, fun), do: do_split_while(binary, fun, 0)

  defp do_split_while(binary, fun, index) do
    case binary do
      <<prefix::binary-size(^index), char::utf8, _::binary>> ->
        if fun.(char) do
          do_split_while(binary, fun, index + byte_size(<<char::utf8>>))
        else
          <<^prefix::binary-size(^index), rest::binary>> = binary
          {prefix, rest}
        end

      <<prefix::binary-size(^index)>> ->
        {prefix, <<>>}
    end
  end
end
