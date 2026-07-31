defmodule Delimited.Error do
  @moduledoc """
  The single error type returned or raised by every `Delimited` operation.

  Match on `:reason`. Show `Exception.message/1` to a human. The reason is part
  of the public contract; the message text is not.

  The struct carries as much position information as the failing operation
  knows. A parse failure knows the line; a cast failure also knows the column,
  the field, and the offending value; a header failure knows neither line nor
  column. Every position field is therefore nullable, and code that reports
  errors must tolerate `nil`.
  """

  @typedoc """
  Why the operation failed.

  Parsing:

    * `:unterminated_quote` - a quoted field was still open at the end of input.
    * `:unescaped_quote` - a character followed a closing quote where only a
      delimiter or a line break is allowed.

  Structure:

    * `:missing_header_row` - the input ended before a header row was read.
    * `:missing_header` - no column in the header row matches a declared field.
    * `:duplicate_header` - a column claimed by a field appears more than once.
    * `:extra_header` - a column is not claimed by any field, and the dialect
      was read with `on_extra_header: :error`.
    * `:row_length_mismatch` - a row holds a different number of cells than the
      header row, or than the schema declares when reading without headers.

  Values:

    * `:cast_failed` - a cell could not be read as the field's type.
    * `:required_field_missing` - a field declared `required: true` had no value.
    * `:dump_failed` - a value could not be written as the field's type.
    * `:missing_value` - a row being written holds no key for a field.

  Environment:

    * `:io_error` - the file could not be opened. `:detail` holds the POSIX
      reason.
  """
  @type reason ::
          :unterminated_quote
          | :unescaped_quote
          | :missing_header_row
          | :missing_header
          | :duplicate_header
          | :extra_header
          | :row_length_mismatch
          | :cast_failed
          | :required_field_missing
          | :dump_failed
          | :missing_value
          | :io_error

  @type t :: %__MODULE__{
          reason: reason(),
          schema: module() | nil,
          field: atom() | nil,
          header: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          value: term(),
          detail: term(),
          path: Path.t() | nil
        }

  defexception [:reason, :schema, :field, :header, :line, :column, :value, :detail, :path]

  @doc false
  @spec new(reason(), keyword()) :: t()
  def new(reason, attributes \\ []) when is_atom(reason) and is_list(attributes) do
    struct!(__MODULE__, [{:reason, reason} | attributes])
  end

  @impl Exception
  def message(%__MODULE__{} = error) do
    location(error) <> describe(error)
  end

  defp location(error) do
    [
      error.path && "#{error.path}",
      error.line && "line #{error.line}",
      error.column && "column #{error.column}",
      error.field && "field #{inspect(error.field)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      segments -> Enum.join(segments, ", ") <> ": "
    end
  end

  defp describe(%{reason: :unterminated_quote}) do
    "a quoted field is still open at the end of the input. " <>
      "Close the quote, or check whether the file was truncated."
  end

  defp describe(%{reason: :unescaped_quote}) do
    "a character follows a closing quote. Only a delimiter or a line break may " <>
      "follow one. Write a literal quote inside a quoted field as two quotes."
  end

  defp describe(%{reason: :missing_header_row}) do
    "the input ended before a header row was read. Supply a file with a header " <>
      "row, or read with `headers: false` to map columns by declaration order."
  end

  defp describe(%{reason: :missing_header, header: header}) do
    "the header row has no column named #{inspect(header)}. Add the column, set " <>
      "`:header` on the field to the name the file uses, or read with " <>
      "`on_missing_header: :ignore` to leave the field at its default."
  end

  defp describe(%{reason: :duplicate_header, header: header}) do
    "the header row holds #{inspect(header)} more than once, so the column a " <>
      "field reads from is ambiguous. Rename one of the columns."
  end

  defp describe(%{reason: :extra_header, header: header}) do
    "the header row holds #{inspect(header)}, which no field declares. Declare a " <>
      "field for it, or read with `on_extra_header: :ignore` to skip the column."
  end

  defp describe(%{reason: :row_length_mismatch, detail: {expected, actual}}) do
    "the row holds #{actual} cells where #{expected} are expected. Repair the " <>
      "row, or check that the dialect's delimiter matches the file."
  end

  defp describe(%{reason: :cast_failed, value: value, detail: expected}) do
    "cannot read #{inspect(value)} as #{expected}. Correct the value, or declare " <>
      "the field with a type that accepts it."
  end

  defp describe(%{reason: :required_field_missing}) do
    "the field is required and the cell is empty. Supply a value, or drop " <>
      "`required: true` from the field."
  end

  defp describe(%{reason: :dump_failed, value: value, detail: expected}) do
    "cannot write #{inspect(value)} as #{expected}. Correct the value in the row, " <>
      "or declare the field with a type that accepts it."
  end

  defp describe(%{reason: :missing_value}) do
    "the row holds no key for this field. Supply the key, using nil for an " <>
      "empty cell, or write rows of the schema's own struct."
  end

  defp describe(%{reason: :io_error, detail: posix}) do
    "cannot open the file (#{inspect(posix)}: #{:file.format_error(posix)}). " <>
      "Check the path, the permissions, and that the parent directory exists."
  end
end
