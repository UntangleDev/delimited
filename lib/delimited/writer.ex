defmodule Delimited.Writer do
  @moduledoc false

  # Turns schema structs into lines.
  #
  # A row may be the schema's struct or a plain map with the same top-level
  # keys, so a computed row does not have to become a struct first. Embedded
  # keys hold the nested maps, structs, or lists declared by the schema. A map
  # missing a key is an error rather than a blank cell: `nil` means a blank
  # value, and the two must not be confused.
  #
  # Line numbers in errors count the header row, so they address the line the
  # file would have had.
  #
  # Each layout renders a row its own way. The delimited layout hands cells to
  # `Delimited.Encoder`, which decides quoting. The fixed layout places each
  # value at its declared position in a record built here. Both take the same
  # values from the same fields, so only the last step differs.

  alias Delimited.Dialect
  alias Delimited.Embed
  alias Delimited.Encoder
  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Reader
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
  @spec row(module(), [Embed.element()], term(), pos_integer(), Dialect.t()) ::
          {:ok, iodata()} | {:error, Error.t()}
  def row(schema, shape, row, line, %Dialect{layout: :fixed} = dialect) when is_map(row) do
    with {:ok, values} <- Embed.values(shape, row),
         {:ok, cells} <- placements(values, dialect),
         {:ok, record} <- record(cells, dialect) do
      {:ok, record}
    else
      {:error, %Error{} = error} -> {:error, %{error | schema: schema, line: line}}
    end
  end

  def row(schema, shape, row, line, %Dialect{} = dialect) when is_map(row) do
    with {:ok, values} <- Embed.values(shape, row),
         {:ok, cells} <- cells(values, dialect) do
      {:ok, Encoder.row(cells, dialect)}
    else
      {:error, %Error{} = error} -> {:error, %{error | schema: schema, line: line}}
    end
  end

  def row(schema, _shape, row, line, _dialect) do
    error =
      Error.new(:dump_failed,
        schema: schema,
        line: line,
        value: row,
        detail: "a #{inspect(schema)} struct or a map with the same keys"
      )

    {:error, error}
  end

  defp cells(values, dialect) do
    reduce_cells(values, dialect, fn _field, _value, cell -> cell end)
  end

  defp placements(values, dialect) do
    reduce_cells(values, dialect, fn field, value, cell ->
      placement(field, IO.iodata_to_binary(cell), value)
    end)
  end

  defp reduce_cells(values, dialect, wrap) do
    values
    |> Enum.reduce_while([], fn {field, value}, cells ->
      case dump(field, value, dialect) do
        {:ok, cell} -> {:cont, [wrap.(field, value, cell) | cells]}
        {:error, error} -> {:halt, %{error | field: field.name}}
      end
    end)
    |> case do
      %Error{} = error -> {:error, error}
      cells -> {:ok, Enum.reverse(cells)}
    end
  end

  # A field with no value is left blank rather than filled with its pad byte.
  # Padding is for values; filling an empty numeric field with zeros would state
  # a number the row never held, and the reader would believe it.
  defp placement(%Field{} = field, text, nil),
    do: {field, text, Field.alignment(field), @filler}

  defp placement(%Field{} = field, text, _value),
    do: {field, text, Field.alignment(field), Field.padding(field)}

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

  defp dump(%Field{required: true}, nil, _dialect) do
    {:error, Error.new(:required_field_missing)}
  end

  defp dump(%Field{} = field, nil, dialect) do
    cell = null(field, dialect)
    preserve(field, nil, cell, dialect)
  end

  defp dump(%Field{} = field, value, dialect) do
    case Type.dump(field.type, value, field.opts) do
      {:ok, cell} -> preserve(field, value, IO.iodata_to_binary(cell), dialect)
      {:error, expected} -> {:error, Error.new(:dump_failed, value: value, detail: expected)}
    end
  end

  # A successful dump is not enough. Trimming, null handling, fixed-width
  # padding, a temporal format, or the type's own cast can still change the
  # value. Apply the same read path before emitting the cell, so the writer
  # refuses data that the declared reader cannot recover.
  defp preserve(field, value, cell, dialect) do
    case rendered_field(field, value, cell, dialect) do
      :too_wide ->
        # `placement/3` owns this error because it can report both byte counts.
        {:ok, cell}

      rendered ->
        preserve_read(field, value, cell, rendered, dialect)
    end
  end

  defp rendered_field(field, value, cell, %{layout: :fixed}) do
    {_offset, width} = field.at
    pad = if is_nil(value), do: @filler, else: Field.padding(field)

    case pad_to(cell, width, Field.alignment(field), pad) do
      {:ok, rendered} -> IO.iodata_to_binary(rendered)
      :too_wide -> :too_wide
    end
  end

  defp rendered_field(_field, _value, cell, _dialect), do: cell

  defp preserve_read(field, value, cell, rendered, dialect) do
    case Reader.read_field(field, rendered, dialect) do
      {:ok, ^value} ->
        {:ok, cell}

      {:ok, read_value} ->
        unrepresentable(value, "it would read back as #{inspect(read_value)}")

      {:error, %Error{reason: reason}} ->
        unrepresentable(value, "the written cell would be refused with #{inspect(reason)}")
    end
  end

  defp unrepresentable(value, detail) do
    {:error, Error.new(:unrepresentable_value, value: value, detail: detail)}
  end

  defp null(%Field{null: [first | _rest]}, _dialect), do: first
  defp null(_field, %{null: [first | _rest]}), do: first
  defp null(_field, _dialect), do: ""
end
