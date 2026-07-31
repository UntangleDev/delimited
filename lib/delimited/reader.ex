defmodule Delimited.Reader do
  @moduledoc false

  # Turns framed rows into schema structs.
  #
  # Three things happen here that a framer cannot know about: rows are skipped,
  # the header row is matched against the declared fields, and each cell is
  # cast. The header row is matched once and the resulting column indices are
  # reused for every later row.
  #
  # A malformed cell fails one row. A malformed header fails the file, because
  # every row after it would be read from the wrong column.
  #
  # Both layouts meet here. Where they differ is what a row carries and how a
  # field finds its text in it: the delimited layout produces cells and a field
  # holds a cell index, the fixed layout produces the record's bytes and a field
  # holds a byte range. The two are told apart by whether the row's payload is a
  # binary, and by nothing else.

  alias Delimited.Dialect
  alias Delimited.Embed
  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Fixed
  alias Delimited.Parser
  alias Delimited.Type

  @type result :: {:ok, struct()} | {:error, Error.t()}

  @spec stream(module(), Enumerable.t(), Dialect.t()) :: Enumerable.t(result())
  def stream(schema, chunks, %Dialect{} = dialect) do
    fields = schema.__delimited__(:fields)

    chunks
    |> frame(dialect)
    |> Stream.concat([:end_of_input])
    |> Stream.transform(initial(fields, dialect), &step(&1, &2, schema, fields, dialect))
  end

  defp frame(chunks, %{layout: :fixed} = dialect), do: Fixed.stream(chunks, dialect)
  defp frame(chunks, dialect), do: Parser.stream(chunks, dialect)

  defp initial(fields, dialect) do
    case skip_count(dialect) do
      0 -> reading(fields, dialect)
      count -> {:skip, count}
    end
  end

  # Under the fixed layout a header row cannot decide anything, because
  # positions already have. It is one more row to drop.
  defp skip_count(%{layout: :fixed, headers: true, skip_rows: rows}), do: rows + 1
  defp skip_count(%{skip_rows: rows}), do: rows

  # The third element is the extent a row must have: a cell count for the
  # delimited layout, a byte count for the fixed one.
  defp reading(fields, %{layout: :fixed}) do
    {:rows, Enum.map(fields, &{&1, &1.at}), fields |> Enum.map(&Field.ends_at/1) |> Enum.max()}
  end

  defp reading(_fields, %{headers: true}), do: :header

  defp reading(fields, _dialect) do
    {:rows, Enum.with_index(fields), length(fields)}
  end

  defp step(_element, :halted, _schema, _fields, _dialect), do: {:halt, :halted}

  defp step({:error, error}, _state, _schema, _fields, _dialect), do: {[{:error, error}], :halted}

  defp step(:end_of_input, :header, schema, _fields, _dialect) do
    {[{:error, Error.new(:missing_header_row, schema: schema)}], :halted}
  end

  defp step(:end_of_input, state, _schema, _fields, _dialect), do: {:halt, state}

  defp step({:ok, _row}, {:skip, 1}, _schema, fields, dialect) do
    {[], reading(fields, dialect)}
  end

  defp step({:ok, _row}, {:skip, remaining}, _schema, _fields, _dialect) do
    {[], {:skip, remaining - 1}}
  end

  defp step({:ok, {line, cells}}, :header, schema, fields, dialect) do
    case build_mapping(schema, fields, cells, line, dialect) do
      {:ok, mapping} -> {[], {:rows, mapping, length(cells)}}
      {:error, errors} -> {Enum.map(errors, &{:error, &1}), :halted}
    end
  end

  defp step({:ok, row}, {:rows, mapping, expected} = state, schema, _fields, dialect) do
    case cast_row(schema, mapping, expected, row, dialect) do
      {:ok, struct} -> {[{:ok, struct}], state}
      {:error, errors} -> {Enum.map(errors, &{:error, &1}), state}
    end
  end

  defp build_mapping(schema, fields, cells, line, dialect) do
    headers = Enum.map(cells, &trim(&1, dialect.trim))

    {mapping, errors} =
      Enum.reduce(fields, {[], []}, fn field, {mapping, errors} ->
        case positions(headers, field.header) do
          [index] ->
            {[{field, index} | mapping], errors}

          [] ->
            {[{field, nil} | mapping], missing_header(field, schema, line, dialect, errors)}

          [_first, _second | _rest] ->
            error =
              Error.new(:duplicate_header,
                schema: schema,
                field: field.name,
                header: field.header,
                line: line
              )

            {[{field, nil} | mapping], [error | errors]}
        end
      end)

    case Enum.reverse(errors) ++ extra_headers(schema, fields, headers, line, dialect) do
      [] -> {:ok, Enum.reverse(mapping)}
      errors -> {:error, errors}
    end
  end

  defp missing_header(_field, _schema, _line, %{on_missing_header: :ignore}, errors), do: errors

  defp missing_header(field, schema, line, _dialect, errors) do
    error =
      Error.new(:missing_header,
        schema: schema,
        field: field.name,
        header: field.header,
        line: line
      )

    [error | errors]
  end

  defp extra_headers(_schema, _fields, _headers, _line, %{on_extra_header: :ignore}), do: []

  defp extra_headers(schema, fields, headers, line, _dialect) do
    declared = MapSet.new(fields, & &1.header)

    headers
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.uniq()
    |> Enum.map(&Error.new(:extra_header, schema: schema, header: &1, line: line))
  end

  defp positions(headers, header) do
    headers
    |> Enum.with_index()
    |> Enum.filter(fn {candidate, _index} -> candidate == header end)
    |> Enum.map(fn {_candidate, index} -> index end)
  end

  # A fixed-width record may hold more bytes than the schema declares: those are
  # filler, ignored the way an undeclared extra column is. It may not hold
  # fewer, because then a declared field is simply not there.
  defp cast_row(schema, mapping, minimum, {line, record}, dialect) when is_binary(record) do
    case byte_size(record) do
      size when size >= minimum ->
        cast_cells(schema, mapping, line, record, dialect)

      size ->
        {:error,
         [
           Error.new(:record_too_short,
             schema: schema,
             line: line,
             detail: {minimum, size}
           )
         ]}
    end
  end

  defp cast_row(schema, mapping, expected, {line, cells}, dialect) do
    case length(cells) do
      ^expected -> cast_cells(schema, mapping, line, List.to_tuple(cells), dialect)
      actual -> {:error, [length_error(schema, line, expected, actual)]}
    end
  end

  # The values come out in the order the fields were declared, which is the
  # order a schema's shape flattens in, so the two are walked together to
  # rebuild whatever nesting the schema declared.
  defp cast_cells(schema, mapping, line, cells, dialect) do
    {values, errors} =
      Enum.reduce(mapping, {[], []}, fn {field, index}, {values, errors} ->
        case cast_cell(field, index, cells, dialect) do
          {:ok, value} ->
            {[value | values], errors}

          {:error, error} ->
            {values, [locate(error, schema, field, line, index) | errors]}
        end
      end)

    case errors do
      [] -> build(schema, Enum.reverse(values), line)
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp build(schema, values, line) do
    case Embed.build(schema.__delimited__(:shape), values, schema, line) do
      {:ok, struct} -> {:ok, struct}
      {:error, errors} -> {:error, Enum.map(errors, &%{&1 | schema: schema})}
    end
  end

  defp cast_cell(%Field{} = field, nil, _row, _dialect), do: absent(field)

  defp cast_cell(%Field{} = field, {offset, length}, record, dialect) do
    text = binary_part(record, offset, length)

    # Slicing by byte can cut a multi-byte character in half, which is what
    # positions counted in characters rather than bytes produce. Refusing the
    # cell reports that; casting the fragments would not.
    if String.valid?(text) do
      text |> unpad(field) |> read(field, dialect)
    else
      {:error, Error.new(:invalid_encoding, value: text)}
    end
  end

  defp cast_cell(%Field{} = field, index, cells, dialect) do
    cells |> elem(index) |> read(field, dialect)
  end

  defp read(text, %Field{} = field, dialect) do
    text = trim(text, trim?(field, dialect))

    if text in nulls(field, dialect) do
      absent(field)
    else
      case Type.cast(field.type, text, field.opts) do
        {:ok, value} -> {:ok, value}
        {:error, expected} -> {:error, Error.new(:cast_failed, value: text, detail: expected)}
      end
    end
  end

  defp unpad(text, %Field{} = field) do
    pad = <<Field.padding(field)>>

    case {strip_padding(text, pad, Field.alignment(field)), pad} do
      # A pad byte that is not a space is a byte a value could be made of, so an
      # all-pad field keeps one of them: "00000000" in a zero-padded numeric
      # field states zero, and reading it as no value at all would be wrong in a
      # way nothing downstream could detect.
      {"", " "} -> ""
      {"", pad} -> pad
      {stripped, " "} -> stripped
      # The same field left blank says the opposite. A file that fills a numeric
      # field with digits when it has a number leaves it blank when it has none,
      # so spaces where digits were expected mean absent, not zero.
      {stripped, _pad} -> if spaces_only?(stripped), do: "", else: stripped
    end
  end

  defp spaces_only?(text), do: String.trim(text, " ") == ""

  defp strip_padding(text, pad, :left), do: String.trim_trailing(text, pad)
  defp strip_padding(text, pad, :right), do: String.trim_leading(text, pad)

  defp absent(%Field{required: true}), do: {:error, Error.new(:required_field_missing)}
  defp absent(%Field{default: default}), do: {:ok, default}

  # A column is the cell's number under the delimited layout and the field's
  # first byte position under the fixed one. Both are what a reader would count
  # to on the line in front of them.
  defp locate(error, schema, field, line, {offset, _length}) do
    %{error | schema: schema, field: field.name, line: line, column: offset + 1}
  end

  defp locate(error, schema, field, line, index) do
    %{error | schema: schema, field: field.name, line: line, column: index && index + 1}
  end

  defp length_error(schema, line, expected, actual) do
    Error.new(:row_length_mismatch, schema: schema, line: line, detail: {expected, actual})
  end

  defp trim?(%Field{trim: nil}, dialect), do: dialect.trim
  defp trim?(%Field{trim: trim}, _dialect), do: trim

  defp nulls(%Field{null: nil}, dialect), do: dialect.null
  defp nulls(%Field{null: null}, _dialect), do: null

  defp trim(text, true), do: String.trim(text)
  defp trim(text, false), do: text
end
