defmodule Delimited.Encoder do
  @moduledoc false

  # Turns cells into one line of a file.
  #
  # The counterpart of `Delimited.Parser`: every cell this writes under a
  # delimited dialect is parsed back unchanged. `escape_formulas: true` is the
  # exception because it deliberately alters the text. `Delimited.Dialect`
  # owns that decision and its limits.

  alias Delimited.Dialect

  # These ASCII leaders can make a spreadsheet import path treat a cell as a
  # formula. `Delimited.Dialect` documents the option's limits.
  @formula_leaders [?=, ?+, ?-, ?@, ?\t, ?\r]

  @numeric ~r/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/

  @doc """
  Encodes one row, including its line break.
  """
  @spec row([iodata()], Dialect.t()) :: iodata()
  def row(cells, %Dialect{} = dialect) do
    encoded =
      cells
      |> Enum.map(&cell(&1, dialect))
      |> lone_empty_cell(dialect)
      |> Enum.intersperse(<<dialect.delimiter>>)

    [encoded, dialect.newline]
  end

  # A one-column row holding no value would otherwise be written as an empty
  # line, which reads back as no row at all. Quoting it keeps the row.
  defp lone_empty_cell([""], dialect), do: [enclose("", dialect)]
  defp lone_empty_cell(cells, _dialect), do: cells

  defp cell(value, dialect) do
    value
    |> IO.iodata_to_binary()
    |> escape_formula(dialect)
    |> quote_cell(dialect)
  end

  defp escape_formula(<<leader, _rest::binary>> = text, %{escape_formulas: true})
       when leader in @formula_leaders do
    if Regex.match?(@numeric, text), do: text, else: "'" <> text
  end

  defp escape_formula(text, _dialect), do: text

  defp quote_cell(text, %{quoting: :always} = dialect), do: enclose(text, dialect)

  defp quote_cell(text, dialect) do
    if needs_quoting?(text, dialect) do
      enclose(text, dialect)
    else
      text
    end
  end

  # `:binary.match/2` compiles a pattern each time it receives a list. That made
  # the default quoting path compile a new pattern for every cell; the write
  # benchmark exposed the repeated work. The parser can compile once per input
  # stream, but the encoder has no state shared by row calls. A direct byte scan
  # avoids both repeated compilation and shared encoder state.
  defp needs_quoting?(text, %{delimiter: delimiter, quote_char: quote_char}),
    do: scan(text, delimiter, quote_char)

  defp scan(<<>>, _delimiter, _quote_char), do: false
  defp scan(<<byte, _rest::binary>>, byte, _quote_char), do: true
  defp scan(<<byte, _rest::binary>>, _delimiter, byte), do: true
  defp scan(<<?\n, _rest::binary>>, _delimiter, _quote_char), do: true
  defp scan(<<?\r, _rest::binary>>, _delimiter, _quote_char), do: true
  defp scan(<<_byte, rest::binary>>, delimiter, quote_char), do: scan(rest, delimiter, quote_char)

  defp enclose(text, dialect) do
    quote_char = <<dialect.quote_char>>

    [
      quote_char,
      :binary.replace(text, quote_char, quote_char <> quote_char, [:global]),
      quote_char
    ]
  end
end
