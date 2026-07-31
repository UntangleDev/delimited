defmodule Delimited.Parser do
  @moduledoc false

  # A resumable RFC 4180 reader.
  #
  # `parse/2` takes an arbitrary slice of the input and returns the rows that
  # slice completed, plus a state that carries the unfinished row into the next
  # slice. Nothing here knows about schemas, types, or files: it turns bytes
  # into `{line, cells}` and reports where it stopped making sense.
  #
  # Deviations from RFC 4180, each because real files rely on them:
  #
  #   * A quote inside an unquoted field is data. `a"b` reads as `a"b`. The RFC
  #     leaves it undefined and there is nothing else it could mean.
  #   * A lone carriage return is data. Only CRLF and LF end a row, so a file
  #     using classic Mac line endings reads as one long row rather than as
  #     silently mangled cells.
  #   * A trailing line break does not produce an empty final row.
  #
  # Line numbers count every line break consumed, including those inside quoted
  # fields, so a reported line matches what an editor shows. A row is reported
  # at the line it starts on.

  alias Delimited.Dialect
  alias Delimited.Error

  defstruct [
    :delimiter,
    :quote_char,
    :comment,
    :stops_unquoted,
    :stops_quoted,
    :skip_blank_lines,
    state: :field_start,
    carry: "",
    field: [],
    fields: [],
    row_content?: false,
    line: 1,
    row_line: 1,
    bom_pending?: true
  ]

  @type row :: {pos_integer(), [String.t()]}
  @opaque t :: %__MODULE__{}

  @bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Builds the initial state for a dialect.
  """
  @spec new(Dialect.t()) :: t()
  def new(%Dialect{} = dialect) do
    %__MODULE__{
      delimiter: dialect.delimiter,
      quote_char: dialect.quote_char,
      comment: dialect.comment,
      stops_unquoted: :binary.compile_pattern([<<dialect.delimiter>>, "\n", "\r"]),
      stops_quoted: :binary.compile_pattern([<<dialect.quote_char>>, "\n"]),
      skip_blank_lines: dialect.skip_blank_lines
    }
  end

  @doc """
  Consumes one slice of input.

  Returns the rows the slice completed and the state to pass to the next call.
  A slice that fails still returns the rows it completed before failing, so that
  where the slices fall cannot change what is read.
  """
  @spec parse(t(), binary()) :: {:ok, [row()], t()} | {:error, [row()], Error.t()}
  def parse(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    data = parser.carry <> chunk
    {parser, data} = handle_bom(%{parser | carry: ""}, data)
    scan(parser, data, [])
  end

  @doc """
  Closes the input, returning any row left unterminated.
  """
  @spec finish(t()) :: {:ok, [row()]} | {:error, Error.t()}
  def finish(%__MODULE__{state: :quoted} = parser) do
    {:error, error(:unterminated_quote, parser, parser.row_line)}
  end

  def finish(%__MODULE__{state: :quote_end, carry: "\r"} = parser) do
    {:error, error(:unescaped_quote, parser, parser.line)}
  end

  def finish(%__MODULE__{} = parser) do
    # A line break immediately before the end of the input closes the last row;
    # it does not open an empty one.
    case flush_carry(parser) do
      %{row_content?: false} -> {:ok, []}
      parser -> {:ok, parser |> close_row([]) |> elem(1) |> Enum.reverse()}
    end
  end

  # A byte order mark can be split across slices, so an incomplete prefix is
  # carried rather than treated as data.
  defp handle_bom(%{bom_pending?: false} = parser, data), do: {parser, data}

  defp handle_bom(parser, @bom <> rest), do: {%{parser | bom_pending?: false}, rest}

  defp handle_bom(parser, data) when byte_size(data) >= 3,
    do: {%{parser | bom_pending?: false}, data}

  defp handle_bom(parser, data) do
    if bom_prefix?(data) do
      {%{parser | carry: data}, ""}
    else
      {%{parser | bom_pending?: false}, data}
    end
  end

  defp bom_prefix?(data), do: :binary.longest_common_prefix([@bom, data]) == byte_size(data)

  defp scan(%{state: :field_start} = parser, <<>>, rows), do: done(parser, rows)

  # A comment is recognised only where a row would start, and consumed without
  # being parsed at all. That is the point of doing it here: a commented line is
  # prose, and prose contains apostrophes and unclosed quotes.
  defp scan(
         %{state: :field_start, comment: comment, row_content?: false} = parser,
         <<comment, rest::binary>>,
         rows
       )
       when is_integer(comment) do
    scan(%{parser | state: :comment}, rest, rows)
  end

  defp scan(%{state: :comment} = parser, data, rows) do
    case :binary.match(data, "\n") do
      :nomatch ->
        done(parser, rows)

      {position, 1} ->
        scan(reset(%{parser | line: parser.line + 1}), advance(data, position + 1), rows)
    end
  end

  defp scan(
         %{state: :field_start, quote_char: quote_char} = parser,
         <<quote_char, rest::binary>>,
         rows
       ) do
    scan(%{parser | state: :quoted, row_content?: true}, rest, rows)
  end

  defp scan(%{state: :field_start} = parser, data, rows) do
    scan(%{parser | state: :unquoted}, data, rows)
  end

  defp scan(%{state: :unquoted} = parser, data, rows) do
    case :binary.match(data, parser.stops_unquoted) do
      :nomatch ->
        done(append(parser, data), rows)

      {position, 1} ->
        {segment, stop, rest} = split(data, position)
        unquoted_stop(append(parser, segment), stop, rest, rows)
    end
  end

  defp scan(%{state: :quoted} = parser, data, rows) do
    case :binary.match(data, parser.stops_quoted) do
      :nomatch ->
        done(append(parser, data), rows)

      {position, 1} ->
        {segment, stop, rest} = split(data, position)
        quoted_stop(append(parser, segment), stop, rest, rows)
    end
  end

  defp scan(%{state: :quote_end} = parser, <<>>, rows), do: done(parser, rows)

  defp scan(
         %{state: :quote_end, quote_char: quote_char} = parser,
         <<quote_char, rest::binary>>,
         rows
       ) do
    scan(%{append(parser, <<quote_char>>) | state: :quoted}, rest, rows)
  end

  defp scan(
         %{state: :quote_end, delimiter: delimiter} = parser,
         <<delimiter, rest::binary>>,
         rows
       ) do
    scan(close_field(parser), rest, rows)
  end

  defp scan(%{state: :quote_end} = parser, <<?\n, rest::binary>>, rows) do
    end_row(parser, rest, rows)
  end

  defp scan(%{state: :quote_end} = parser, <<?\r>>, rows), do: done(%{parser | carry: "\r"}, rows)

  defp scan(%{state: :quote_end} = parser, <<?\r, ?\n, rest::binary>>, rows) do
    end_row(parser, rest, rows)
  end

  defp scan(%{state: :quote_end} = parser, _data, rows) do
    {:error, Enum.reverse(rows), error(:unescaped_quote, parser, parser.line)}
  end

  defp advance(data, position),
    do: binary_part(data, position, byte_size(data) - position)

  # Both halves are sub-binaries of `data` rather than copies of it.
  defp split(data, position) do
    <<stop, rest::binary>> = binary_part(data, position, byte_size(data) - position)
    {binary_part(data, 0, position), stop, rest}
  end

  defp unquoted_stop(%{delimiter: delimiter} = parser, delimiter, rest, rows) do
    scan(close_field(parser), rest, rows)
  end

  defp unquoted_stop(parser, ?\n, rest, rows), do: end_row(parser, rest, rows)

  defp unquoted_stop(parser, ?\r, <<>>, rows), do: done(%{parser | carry: "\r"}, rows)

  defp unquoted_stop(parser, ?\r, <<?\n, rest::binary>>, rows), do: end_row(parser, rest, rows)

  defp unquoted_stop(parser, ?\r, rest, rows), do: scan(append(parser, "\r"), rest, rows)

  defp quoted_stop(%{quote_char: quote_char} = parser, quote_char, rest, rows) do
    scan(%{parser | state: :quote_end}, rest, rows)
  end

  defp quoted_stop(parser, ?\n, rest, rows) do
    scan(%{append(parser, "\n") | line: parser.line + 1}, rest, rows)
  end

  defp end_row(parser, rest, rows) do
    {parser, rows} = close_row(%{parser | line: parser.line + 1}, rows)
    scan(parser, rest, rows)
  end

  defp append(parser, ""), do: parser

  defp append(parser, segment) do
    %{parser | field: [parser.field | [segment]], row_content?: true}
  end

  defp close_field(parser) do
    %{
      parser
      | fields: [IO.iodata_to_binary(parser.field) | parser.fields],
        field: [],
        state: :field_start,
        row_content?: true
    }
  end

  defp close_row(%{row_content?: false, skip_blank_lines: true} = parser, rows) do
    {reset(parser), rows}
  end

  defp close_row(parser, rows) do
    cells = Enum.reverse([IO.iodata_to_binary(parser.field) | parser.fields])
    {reset(parser), [{parser.row_line, cells} | rows]}
  end

  defp reset(parser) do
    %{
      parser
      | fields: [],
        field: [],
        state: :field_start,
        row_content?: false,
        row_line: parser.line
    }
  end

  # A carriage return held back at the end of a slice turned out to be data,
  # because no line feed followed it before the input ended.
  defp flush_carry(%{carry: "\r"} = parser), do: append(%{parser | carry: ""}, "\r")
  defp flush_carry(parser), do: parser

  defp done(parser, rows), do: {:ok, Enum.reverse(rows), parser}

  defp error(reason, parser, line) do
    Error.new(reason, line: line, column: length(parser.fields) + 1)
  end

  @doc """
  Reads a stream of slices as a stream of rows.

  Emits `{:ok, row}` until the first `{:error, error}`, which ends the stream:
  once a quote or a row boundary is misplaced, every later row is guesswork.
  """
  @spec stream(Enumerable.t(), Dialect.t()) ::
          Enumerable.t({:ok, row()} | {:error, Error.t()})
  def stream(chunks, %Dialect{} = dialect) do
    chunks
    |> Stream.concat([:end_of_input])
    |> Stream.transform({:parsing, new(dialect)}, &step/2)
  end

  defp step(_element, :halted), do: {:halt, :halted}

  defp step(:end_of_input, {:parsing, parser}) do
    case finish(parser) do
      {:ok, rows} -> {Enum.map(rows, &{:ok, &1}), :halted}
      {:error, error} -> {[{:error, error}], :halted}
    end
  end

  defp step(chunk, {:parsing, parser}) when is_binary(chunk) do
    case parse(parser, chunk) do
      {:ok, rows, parser} -> {Enum.map(rows, &{:ok, &1}), {:parsing, parser}}
      {:error, rows, error} -> {Enum.map(rows, &{:ok, &1}) ++ [{:error, error}], :halted}
    end
  end

  defp step(other, {:parsing, _parser}) do
    raise ArgumentError,
          "expected the source to yield binaries, got: #{inspect(other)}. " <>
            "Read a file with a path, or pass a stream of binary slices."
  end
end
