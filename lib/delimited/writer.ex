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

  alias Delimited.Dialect
  alias Delimited.Encoder
  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Type

  @bom <<0xEF, 0xBB, 0xBF>>

  @spec prelude([Field.t()], Dialect.t()) :: iodata()
  def prelude(fields, %Dialect{} = dialect) do
    [
      if(dialect.bom, do: @bom, else: []),
      if(dialect.headers, do: Encoder.row(Enum.map(fields, & &1.header), dialect), else: [])
    ]
  end

  @doc """
  Encodes one row. `line` is the line the row occupies in the output.
  """
  @spec row(module(), [Field.t()], term(), pos_integer(), Dialect.t()) ::
          {:ok, iodata()} | {:error, Error.t()}
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
