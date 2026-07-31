defmodule Delimited.Reader do
  @moduledoc false

  # Turns the parser's rows into schema structs.
  #
  # Three things happen here that the parser cannot know about: rows are
  # skipped, the header row is matched against the declared fields, and each
  # cell is cast. The header row is matched once and the resulting column
  # indices are reused for every later row.
  #
  # A malformed cell fails one row. A malformed header fails the file, because
  # every row after it would be read from the wrong column.

  alias Delimited.Dialect
  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Parser
  alias Delimited.Type

  @type result :: {:ok, struct()} | {:error, Error.t()}

  @spec stream(module(), Enumerable.t(), Dialect.t()) :: Enumerable.t(result())
  def stream(schema, chunks, %Dialect{} = dialect) do
    fields = schema.__delimited__(:fields)

    chunks
    |> Parser.stream(dialect)
    |> Stream.concat([:end_of_input])
    |> Stream.transform(initial(fields, dialect), &step(&1, &2, schema, fields, dialect))
  end

  defp initial(_fields, %{skip_rows: rows}) when rows > 0, do: {:skip, rows}
  defp initial(_fields, %{headers: true}), do: :header

  defp initial(fields, _dialect) do
    {:rows, Enum.with_index(fields), length(fields)}
  end

  defp step(_element, :halted, _schema, _fields, _dialect), do: {:halt, :halted}

  defp step({:error, error}, _state, _schema, _fields, _dialect), do: {[{:error, error}], :halted}

  defp step(:end_of_input, :header, schema, _fields, _dialect) do
    {[{:error, Error.new(:missing_header_row, schema: schema)}], :halted}
  end

  defp step(:end_of_input, state, _schema, _fields, _dialect), do: {:halt, state}

  defp step({:ok, _row}, {:skip, 1}, _schema, fields, dialect) do
    {[], initial(fields, %{dialect | skip_rows: 0})}
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

  defp cast_row(schema, mapping, expected, {line, cells}, dialect) do
    case length(cells) do
      ^expected -> cast_cells(schema, mapping, line, List.to_tuple(cells), dialect)
      actual -> {:error, [length_error(schema, line, expected, actual)]}
    end
  end

  defp cast_cells(schema, mapping, line, cells, dialect) do
    {values, errors} =
      Enum.reduce(mapping, {[], []}, fn {field, index}, {values, errors} ->
        case cast_cell(field, index, cells, dialect) do
          {:ok, value} ->
            {[{field.name, value} | values], errors}

          {:error, error} ->
            {values, [locate(error, schema, field, line, index) | errors]}
        end
      end)

    case errors do
      [] -> {:ok, struct!(schema, values)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp cast_cell(%Field{} = field, nil, _cells, _dialect), do: absent(field)

  defp cast_cell(%Field{} = field, index, cells, dialect) do
    text = cells |> elem(index) |> trim(trim?(field, dialect))

    if text in nulls(field, dialect) do
      absent(field)
    else
      case Type.cast(field.type, text, field.opts) do
        {:ok, value} -> {:ok, value}
        {:error, expected} -> {:error, Error.new(:cast_failed, value: text, detail: expected)}
      end
    end
  end

  defp absent(%Field{required: true}), do: {:error, Error.new(:required_field_missing)}
  defp absent(%Field{default: default}), do: {:ok, default}

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
