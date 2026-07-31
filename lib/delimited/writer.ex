defmodule Delimited.Writer do
  @moduledoc false

  # Turns schema structs into lines.
  #
  # A row may be the schema's struct or a plain map holding every field's key,
  # so a row computed on the way out does not have to be built into a struct
  # first. A map missing a key is an error rather than a blank cell: a blank
  # cell is what `nil` means, and the two must not be confused.
  #
  # Line numbers in errors count the header row, so they address the line the
  # file would have had.
  #
  # Each layout renders a row its own way. The delimited layout hands cells to
  # `Delimited.Encoder`, which decides quoting. The fixed layout places each
  # value at its declared position in a record built here. Both take the same
  # values from the same fields, so only the last step differs.

  alias Delimited.Dialect
  alias Delimited.Encoder
  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Type

  @bom <<0xEF, 0xBB, 0xBF>>

  # A position no field declares is filler. These formats write filler blank,
  # whatever a neighbouring field pads itself with.
  @filler ?\s

  @doc """
  Encodes whatever precedes the first row: a byte order mark, a header row, or
  neither.
  """
  @spec prelude([Field.t()], Dialect.t()) :: {:ok, iodata()} | {:error, Error.t()}
  def prelude(fields, %Dialect{} = dialect) do
    with {:ok, header} <- header_row(fields, dialect) do
      {:ok, [if(dialect.bom, do: @bom, else: []), header]}
    end
  end

  defp header_row(_fields, %{headers: false}), do: {:ok, []}

  defp header_row(fields, %{layout: :fixed} = dialect) do
    # A header is text, so it is placed like text however its field pads its
    # own values: a zero-padded amount column would otherwise be headed
    # "000AMOUNT".
    fields
    |> Enum.map(&{&1, &1.header, :left, @filler})
    |> record(dialect)
  end

  defp header_row(fields, dialect) do
    {:ok, Encoder.row(Enum.map(fields, & &1.header), dialect)}
  end

  @doc """
  Encodes one row. `line` is the line the row occupies in the output.
  """
  @spec row(module(), [Field.t()], term(), pos_integer(), Dialect.t()) ::
          {:ok, iodata()} | {:error, Error.t()}
  def row(schema, fields, row, line, %Dialect{layout: :fixed} = dialect) when is_map(row) do
    with {:ok, cells} <- placements(schema, fields, row, line, dialect),
         {:ok, record} <- record(cells, dialect) do
      {:ok, record}
    else
      {:error, %Error{} = error} -> {:error, %{error | schema: schema, line: line}}
    end
  end

  def row(schema, fields, row, line, %Dialect{} = dialect) when is_map(row) do
    fields
    |> Enum.reduce_while([], fn field, cells ->
      case cell(field, row, dialect) do
        {:ok, cell} -> {:cont, [cell | cells]}
        {:error, error} -> {:halt, locate(error, schema, field, line)}
      end
    end)
    |> case do
      %Error{} = error -> {:error, error}
      cells -> {:ok, Encoder.row(Enum.reverse(cells), dialect)}
    end
  end

  def row(schema, _fields, row, line, _dialect) do
    error =
      Error.new(:dump_failed,
        schema: schema,
        line: line,
        value: row,
        detail: "a #{inspect(schema)} struct or a map with the same keys"
      )

    {:error, error}
  end

  defp placements(schema, fields, row, line, dialect) do
    fields
    |> Enum.reduce_while([], fn field, cells ->
      case cell(field, row, dialect) do
        {:ok, cell} ->
          {:cont, [placement(field, IO.iodata_to_binary(cell), row) | cells]}

        {:error, error} ->
          {:halt, locate(error, schema, field, line)}
      end
    end)
    |> case do
      %Error{} = error -> {:error, error}
      cells -> {:ok, cells}
    end
  end

  # A field with no value is left blank rather than filled with its pad byte.
  # Padding is for values; filling an empty numeric field with zeros would state
  # a number the row never held, and the reader would believe it.
  defp placement(%Field{} = field, text, row) do
    case Map.get(row, field.name) do
      nil -> {field, text, Field.alignment(field), @filler}
      _value -> {field, text, Field.alignment(field), Field.padding(field)}
    end
  end

  # Fields are placed in position order rather than declaration order, so that
  # a schema may declare them in whatever order reads best.
  defp record(cells, %Dialect{} = dialect) do
    cells
    |> Enum.sort_by(fn {field, _text, _align, _pad} -> field.at end)
    |> Enum.reduce_while({[], 0}, &place/2)
    |> case do
      {:too_wide, error} ->
        {:error, error}

      {iodata, cursor} ->
        {:ok, [iodata, trailing(cursor, dialect), terminator(dialect)]}
    end
  end

  defp place({field, text, align, pad}, {iodata, cursor}) do
    {offset, width} = field.at

    case pad_to(text, width, align, pad) do
      {:ok, padded} ->
        {:cont, {[iodata, filler(offset - cursor), padded], offset + width}}

      :too_wide ->
        error =
          Error.new(:value_too_wide,
            field: field.name,
            value: text,
            column: offset + 1,
            detail: {width, byte_size(text)}
          )

        {:halt, {:too_wide, error}}
    end
  end

  defp pad_to(text, width, align, pad) do
    size = byte_size(text)

    cond do
      size > width -> :too_wide
      align == :left -> {:ok, [text, :binary.copy(<<pad>>, width - size)]}
      true -> {:ok, [:binary.copy(<<pad>>, width - size), text]}
    end
  end

  defp filler(0), do: []
  defp filler(width), do: :binary.copy(<<@filler>>, width)

  # A record framed by its length is padded out to that length. One framed by
  # its line ends where its last field does.
  defp trailing(_cursor, %{record_length: :line}), do: []
  defp trailing(cursor, %{record_length: length}), do: filler(max(length - cursor, 0))

  defp terminator(%{record_length: :line, newline: newline}), do: newline
  defp terminator(_dialect), do: []

  defp cell(%Field{} = field, row, dialect) do
    case Map.fetch(row, field.name) do
      {:ok, nil} -> {:ok, null(field, dialect)}
      {:ok, value} -> dump(field, value)
      :error -> {:error, missing_key(field)}
    end
  end

  defp dump(%Field{} = field, value) do
    case Type.dump(field.type, value, field.opts) do
      {:ok, cell} -> {:ok, cell}
      {:error, expected} -> {:error, Error.new(:dump_failed, value: value, detail: expected)}
    end
  end

  defp missing_key(%Field{} = field), do: Error.new(:missing_value, field: field.name)

  defp null(%Field{null: [first | _rest]}, _dialect), do: first
  defp null(_field, %{null: [first | _rest]}), do: first
  defp null(_field, _dialect), do: ""

  defp locate(error, schema, field, line) do
    %{error | schema: schema, field: field.name, line: line}
  end
end
