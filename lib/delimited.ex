defmodule Delimited do
  @moduledoc """
  Reads and writes CSV, TSV, and other delimited files through a declared
  schema.

      defmodule Employee do
        use Delimited.Schema

        delimited_schema do
          field :id, :integer, header: "Employee ID"
          field :name, :string, required: true
          field :hired_on, :date, header: "Hire Date"
          field :active, :boolean, default: true
        end
      end

      {:ok, employees} = Delimited.read(Employee, "employees.csv")
      :ok = Delimited.write(Employee, "employees.tsv", employees, :tsv)

  The schema is the contract. A column the file holds and the schema does not
  declare is ignored; a column the schema declares and the file does not hold is
  an error, because that is the shape a renamed column takes and it would
  otherwise read as a column of `nil`.

  ## Choosing a function

  | You have | You want | Use |
  |---|---|---|
  | a path | every row, or the errors | `read/3` |
  | a path | every row, or an exception | `read!/3` |
  | a path, or a stream of slices | rows as they arrive | `stream/3` |
  | a binary in memory | every row, or the errors | `decode/3` |
  | rows | a file on disk | `write/4` |
  | rows | a stream of iodata | `encode!/3` |

  `read/3` collects every row before returning. `stream/3` holds one slice and
  one row at a time, and is the one to reach for when a file is larger than the
  memory you want to spend on it.

  ## Errors

  Every failure is a `Delimited.Error` carrying a `:reason` to match on and as
  much of the path, line, column, and field as the failure knows.

  A parse failure ends the file: after a misplaced quote, no later row can be
  trusted. A cast failure fails only its own row, so one unreadable date does
  not cost you the other 99,999 rows.

      case Delimited.read(Employee, "employees.csv") do
        {:ok, employees} -> employees
        {:error, errors} -> Enum.map(errors, &Exception.message/1)
      end

  ## Options

  Every function accepts the options in `Delimited.Dialect`, or a format name
  such as `:tsv`, applied on top of what the schema declared.

  Read `Delimited.Dialect` before writing a file that another program will open
  as a spreadsheet. Its `:escape_formulas` note describes an injection that this
  library does not defend against by default, and why.
  """

  alias Delimited.Dialect
  alias Delimited.Error
  alias Delimited.Reader
  alias Delimited.Schema
  alias Delimited.Writer

  @typedoc "Dialect options, or the name of a format such as `:csv` or `:tsv`."
  @type options :: keyword() | atom()

  @typedoc "A path to read, or an enumerable of binary slices."
  @type source :: Path.t() | Enumerable.t()

  @typedoc "A row to write: the schema's struct, or a map holding every field's key."
  @type row :: struct() | map()

  @read_modes [:read, :binary, :read_ahead]
  @write_modes [:write, :binary, :delayed_write]

  @doc """
  Reads every row of the file at `path`.

  Returns `{:ok, rows}`, or `{:error, errors}` holding every error found. One
  unreadable cell does not discard the rows around it, so the error list is
  where to look for what a supplier keeps getting wrong.

      {:ok, employees} = Delimited.read(Employee, "employees.csv")
      {:ok, employees} = Delimited.read(Employee, "employees.txt", delimiter: "|")

  Both the rows and the errors are held in memory. Use `stream/3` for a file too
  large for that.
  """
  @spec read(module(), Path.t(), options()) :: {:ok, [row()]} | {:error, [Error.t()]}
  def read(schema, path, opts \\ []) when is_binary(path) do
    dialect = Schema.dialect_for!(schema, opts)

    case File.open(path, @read_modes) do
      {:ok, device} ->
        try do
          schema
          |> Reader.stream(device_slices(device, path, dialect.chunk_size), dialect)
          |> collect(path)
        after
          File.close(device)
        end

      {:error, posix} ->
        {:error, [io_error(schema, path, posix)]}
    end
  end

  @doc """
  Reads every row of the file at `path`, or raises the first error.

  Use it where an unreadable file is a broken deployment rather than a case to
  handle: a fixture, a build step, a one-off script.
  """
  @spec read!(module(), Path.t(), options()) :: [row()]
  def read!(schema, path, opts \\ []) when is_binary(path) do
    case read(schema, path, opts) do
      {:ok, rows} -> rows
      {:error, [error | _rest]} -> raise error
    end
  end

  @doc """
  Reads a file, or a stream of binary slices, one row at a time.

  Emits `{:ok, row}` and `{:error, error}` in the order they occur. The stream
  ends at the first parse error, because a file whose quoting or row boundaries
  are wrong cannot be read further. It continues past a cast error.

  Give a path to read a file, or any enumerable of binaries to read something
  that arrives in pieces, such as an upload or a decompressed response.

      Employee
      |> Delimited.stream("employees.csv")
      |> Stream.each(&report_error/1)
      |> Stream.filter(&match?({:ok, _row}, &1))
      |> Enum.each(fn {:ok, employee} -> insert(employee) end)

  Reading a path opens the file when the stream is first enumerated, and raises
  `File.Error` if it cannot be opened, in the manner of `File.stream!/3`. Use
  `read/3` where an unopenable file should be a value rather than an exception.
  """
  @spec stream(module(), source(), options()) ::
          Enumerable.t({:ok, row()} | {:error, Error.t()})
  def stream(schema, source, opts \\ [])

  def stream(schema, path, opts) when is_binary(path) do
    dialect = Schema.dialect_for!(schema, opts)

    schema
    |> Reader.stream(file_slices(path, dialect.chunk_size), dialect)
    |> Stream.map(&put_path(&1, path))
  end

  def stream(schema, slices, opts) do
    Reader.stream(schema, slices, Schema.dialect_for!(schema, opts))
  end

  @doc """
  Reads rows from a binary, or an enumerable of binary slices, already in
  memory.

  The counterpart of `read/3` for data that never was a file: a response body, a
  database column, a fixture written inline.

      {:ok, [employee]} = Delimited.decode(Employee, "Employee ID,name\\n1,Ada\\n")
  """
  @spec decode(module(), binary() | Enumerable.t(), options()) ::
          {:ok, [row()]} | {:error, [Error.t()]}
  def decode(schema, data, opts \\ [])

  def decode(schema, data, opts) when is_binary(data), do: decode(schema, [data], opts)

  def decode(schema, slices, opts) do
    schema
    |> Reader.stream(slices, Schema.dialect_for!(schema, opts))
    |> collect(nil)
  end

  @doc """
  Reads rows from a binary in memory, or raises the first error.
  """
  @spec decode!(module(), binary() | Enumerable.t(), options()) :: [row()]
  def decode!(schema, data, opts \\ []) do
    case decode(schema, data, opts) do
      {:ok, rows} -> rows
      {:error, [error | _rest]} -> raise error
    end
  end

  @doc """
  Writes `rows` to the file at `path`, replacing whatever is there.

  A row may be the schema's struct, or any map holding a key for every declared
  field.

      :ok = Delimited.write(Employee, "employees.csv", employees)
      :ok = Delimited.write(Employee, "employees.tsv", employees, :tsv)

  Returns `{:error, error}` for the first row that cannot be written, or if the
  file cannot be opened or closed. The rows before a failed row are already on
  disk: write to a temporary path and rename it if a half-written file would be
  worse than no file.
  """
  @spec write(module(), Path.t(), Enumerable.t(row()), options()) :: :ok | {:error, Error.t()}
  def write(schema, path, rows, opts \\ []) when is_binary(path) do
    dialect = Schema.dialect_for!(schema, opts)
    fields = schema.__delimited__(:fields)

    case File.open(path, @write_modes) do
      {:ok, device} ->
        try do
          with :ok <- write_rows(device, schema, fields, rows, dialect, path) do
            close(device, schema, path)
          end
        after
          File.close(device)
        end

      {:error, posix} ->
        {:error, io_error(schema, path, posix)}
    end
  end

  @doc """
  Writes `rows` to the file at `path`, or raises.
  """
  @spec write!(module(), Path.t(), Enumerable.t(row()), options()) :: :ok
  def write!(schema, path, rows, opts \\ []) do
    case write(schema, path, rows, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Encodes `rows` as a stream of iodata, one element per line.

  Raises `Delimited.Error` for a row that cannot be written, because a value
  that does not match its declared type is a fault in the program rather than in
  the data. Use `write/4` where you want that as a value.

  The stream is lazy, so an export never exists in memory all at once:

      Employee
      |> Delimited.encode!(Repo.stream(query))
      |> Enum.into(File.stream!("employees.csv"))

  For an export small enough to hold:

      Employee
      |> Delimited.encode!(employees)
      |> Enum.to_list()
      |> IO.iodata_to_binary()
  """
  @spec encode!(module(), Enumerable.t(row()), options()) :: Enumerable.t(iodata())
  def encode!(schema, rows, opts \\ []) do
    dialect = Schema.dialect_for!(schema, opts)
    fields = schema.__delimited__(:fields)

    encoded =
      rows
      |> Stream.with_index(first_row_line(dialect))
      |> Stream.map(fn {row, line} ->
        case Writer.row(schema, fields, row, line, dialect) do
          {:ok, iodata} -> iodata
          {:error, error} -> raise error
        end
      end)

    Stream.concat([Writer.prelude(fields, dialect)], encoded)
  end

  @doc """
  Returns the header row that a file for `schema` would have.

  Use it to generate a blank template for whoever has to fill one in, so that
  the schema and the template cannot disagree.

      Delimited.headers(Employee)
      #=> ["Employee ID", "name", "Hire Date", "active"]
  """
  @spec headers(module()) :: [String.t()]
  def headers(schema) do
    schema = Schema.ensure_schema!(schema)

    Enum.map(schema.__delimited__(:fields), & &1.header)
  end

  @doc """
  Returns the dialect that `schema` declared, before any call-site options.
  """
  @spec dialect(module()) :: Dialect.t()
  def dialect(schema) do
    schema = Schema.ensure_schema!(schema)

    schema.__delimited__(:dialect)
  end

  defp first_row_line(%{headers: true}), do: 2
  defp first_row_line(_dialect), do: 1

  defp write_rows(device, schema, fields, rows, dialect, path) do
    with :ok <- binwrite(device, Writer.prelude(fields, dialect), schema, path) do
      rows
      |> Stream.with_index(first_row_line(dialect))
      |> Enum.reduce_while(:ok, fn {row, line}, :ok ->
        device |> write_row(schema, fields, row, line, dialect, path) |> continue()
      end)
    end
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, error}), do: {:halt, {:error, error}}

  defp write_row(device, schema, fields, row, line, dialect, path) do
    with {:ok, iodata} <- Writer.row(schema, fields, row, line, dialect) do
      binwrite(device, iodata, schema, path)
    end
  end

  # `:file.write/2` rather than `IO.binwrite/2`, because it reports a failed
  # write as a value. `IO.binwrite/2` is specified to return `:ok`.
  defp binwrite(device, iodata, schema, path) do
    case :file.write(device, iodata) do
      :ok -> :ok
      {:error, posix} -> {:error, io_error(schema, path, posix)}
    end
  end

  # Closing is where a delayed write reports a full disk, so its result is part
  # of whether the file was written. The `after` clause closes a second time,
  # which is harmless, rather than leaving the device open if a row raises.
  defp close(device, schema, path) do
    case File.close(device) do
      :ok -> :ok
      {:error, posix} -> {:error, io_error(schema, path, posix)}
    end
  end

  defp io_error(schema, path, posix) do
    Error.new(:io_error, schema: schema, path: path, detail: posix)
  end

  defp file_slices(path, chunk_size) do
    Stream.resource(
      fn -> File.open!(path, @read_modes) end,
      &read_slice(&1, path, chunk_size),
      &File.close/1
    )
  end

  defp device_slices(device, path, chunk_size) do
    Stream.resource(
      fn -> device end,
      &read_slice(&1, path, chunk_size),
      fn _device -> :ok end
    )
  end

  defp read_slice(device, path, chunk_size) do
    case IO.binread(device, chunk_size) do
      :eof -> {:halt, device}
      data when is_binary(data) -> {[data], device}
      {:error, posix} -> raise File.Error, reason: posix, action: "read from", path: path
    end
  end

  defp collect(results, path) do
    {rows, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, row}, {rows, errors} -> {[row | rows], errors}
        {:error, error}, {rows, errors} -> {rows, [put_path(error, path) | errors]}
      end)

    case errors do
      [] -> {:ok, Enum.reverse(rows)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp put_path(result, nil), do: result
  defp put_path({:ok, _row} = result, _path), do: result
  defp put_path({:error, %Error{} = error}, path), do: {:error, %{error | path: path}}
  defp put_path(%Error{} = error, path), do: %{error | path: path}
end
