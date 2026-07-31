defmodule Delimited.Dialect do
  @moduledoc """
  How a file is punctuated, separately from what its columns mean.

  A schema carries the dialect it was declared with. Every read and write
  accepts the same options and applies them on top, so one schema can read the
  comma-separated export and the tab-separated feed without being declared
  twice.

      delimited_schema :tsv do
        field :sku, :string
      end

      Delimited.read(Product, "supplier.csv", delimiter: ",")

  ## Formats

  `:csv` uses a comma. `:tsv` uses a tab and is otherwise identical, which means
  quoting still applies. That is deliberate: the tab-separated files that tools
  actually produce quote fields containing tabs, while the IANA
  `text/tab-separated-values` registration forbids such fields outright. Reading
  a file that follows the registration works either way; writing produces a file
  the registration does not describe only when a value contains a tab, a quote,
  or a line break.

  `:psv` uses a pipe and `:ssv` a single space. A space-separated file is the
  one to be most careful with: a single space is a delimiter like any other, so
  two spaces make an empty cell between them rather than one wider gap. A file
  that aligns its columns with runs of spaces is a fixed-width file, and
  `layout: :fixed` reads it.

  `:fixed` selects the fixed-width layout and turns `:headers` off, since a
  fixed-width file rarely carries a header row.

  A format applies exactly the options it names and leaves every other option as
  it found it, so `merge!(dialect, :tsv)` changes the delimiter without
  disturbing the null strings.

  ## Layouts

  `layout: :delimited` (the default) finds a cell between two delimiters.
  `layout: :fixed` takes a cell from the byte range each field declares with
  `:at`, and the delimiter and quote character are then unused. See
  `Delimited.Field` for declaring positions.

  The layout also decides how records are framed:

    * `record_length: :line` (the default) frames a record as a line, however
      long the line is.
    * `record_length: N` frames a record as exactly N bytes, for a file with no
      line terminators at all. A file that has terminators is framed by its
      lines whatever its record length, so there is never a question of whether
      a terminator is part of the record or between two of them.

  ## Options

  Reading and writing:

    * `:layout` - `:delimited` (default) or `:fixed`.
    * `:record_length` - `:line` (default) or a positive integer. Fixed layout
      only.
    * `:delimiter` - the byte between cells, as a one-character string or a
      codepoint. Defaults to `?,`. Delimited layout only.
    * `:quote_char` - the byte that quotes a cell. Defaults to `?"`. Delimited
      layout only.
    * `:headers` - whether the file has a header row. Under the delimited
      layout, `false` matches columns by declaration order. Under the fixed
      layout, positions always decide, so `true` only means that the first
      record is a header line to skip when reading and to write when writing.
      Defaults to `true`, and to `false` under the `:fixed` format.
    * `:trim` - strip surrounding whitespace from every cell. Defaults to
      `false`, so that a value is read exactly as the file holds it. Overridable
      per field.
    * `:null` - the strings that mean "no value". Defaults to `[""]`. When
      writing, `nil` becomes the first string in the list. Overridable per
      field.

  Reading only:

    * `:comment` - a byte that marks a whole line as a comment, as a
      one-character string or a codepoint. Defaults to `nil`, meaning no line is
      a comment. A commented line is discarded while the file is being framed,
      before any cell is read, so it may hold anything at all including an
      unclosed quote.
    * `:skip_rows` - discard this many rows before the header row. Use it for
      the export that starts with a title and a blank line. Defaults to `0`.
    * `:skip_blank_lines` - ignore lines holding no cells at all. Defaults to
      `true`. A line of only whitespace is not blank; it is a one-cell row.
    * `:on_missing_header` - `:error` (default) or `:ignore`. Ignoring leaves
      the field at its default for every row, which is why it is not the
      default: a renamed column would otherwise read as an entire column of
      `nil`.
    * `:on_extra_header` - `:ignore` (default) or `:error`. A schema names the
      columns it wants, so extra columns are normally the file's business.
    * `:chunk_size` - bytes read from the file at a time. Defaults to 65_536.

  Writing only:

    * `:newline` - `"\\n"` (default) or `"\\r\\n"`. RFC 4180 specifies CRLF;
      most tools accept either.
    * `:quoting` - `:as_needed` (default) quotes a cell only when it holds a
      delimiter, a quote, or a line break. `:always` quotes every cell.
    * `:bom` - write a UTF-8 byte order mark. Defaults to `false`. Excel needs
      it to read UTF-8 correctly. Reading strips a byte order mark either way.
    * `:escape_formulas` - prefix a cell that a spreadsheet would evaluate with
      an apostrophe. Defaults to `false`. See the security note below.

  ## Formula escaping

  A cell beginning with `=`, `+`, `-`, `@`, a tab, or a carriage return is
  executed as a formula by Excel, LibreOffice, and Google Sheets when the file
  is opened. A file assembled from untrusted input can therefore run a command
  on the reader's machine. `escape_formulas: true` prefixes such a cell with an
  apostrophe, which those programs strip on display.

  It is off by default because it changes the data: a file written with it and
  read back yields `'=SUM(A1)`, not `=SUM(A1)`. Correctness of the round trip
  wins over a defence against a hazard in a different program, and the choice is
  documented here rather than made silently.

  Values that read as numbers are never prefixed, so `-1.5` survives. The
  defence covers the leading character only. It does not sanitise a cell a
  spreadsheet interprets in some other way, does not protect a consumer that
  splits on delimiters differently, and is no substitute for the consumer
  opening the file as data rather than as a spreadsheet.
  """

  @default_delimiter ?,
  @default_quote ?"

  defstruct delimiter: @default_delimiter,
            quote_char: @default_quote,
            comment: nil,
            layout: :delimited,
            record_length: :line,
            newline: "\n",
            headers: true,
            skip_rows: 0,
            trim: false,
            null: [""],
            skip_blank_lines: true,
            on_missing_header: :error,
            on_extra_header: :ignore,
            quoting: :as_needed,
            bom: false,
            escape_formulas: false,
            chunk_size: 65_536

  @type t :: %__MODULE__{
          delimiter: byte(),
          quote_char: byte(),
          comment: byte() | nil,
          layout: :delimited | :fixed,
          record_length: :line | pos_integer(),
          newline: String.t(),
          headers: boolean(),
          skip_rows: non_neg_integer(),
          trim: boolean(),
          null: [String.t()],
          skip_blank_lines: boolean(),
          on_missing_header: :error | :ignore,
          on_extra_header: :error | :ignore,
          quoting: :as_needed | :always,
          bom: boolean(),
          escape_formulas: boolean(),
          chunk_size: pos_integer()
        }

  # A format is a set of options, not only a delimiter, so that a name can carry
  # everything that distinguishes one shape of file from another. A format
  # applies exactly the options listed here and leaves every other option as it
  # found it.
  @formats [
    csv: [layout: :delimited, delimiter: @default_delimiter],
    tsv: [layout: :delimited, delimiter: ?\t],
    psv: [layout: :delimited, delimiter: ?|],
    ssv: [layout: :delimited, delimiter: ?\s],
    fixed: [layout: :fixed, headers: false]
  ]

  @doc """
  Builds a dialect from a format name, a keyword list of options, or both.

  Raises `ArgumentError` for an unknown format, an unknown option, or an option
  the reader cannot honour. A dialect is programmer-owned configuration rather
  than data read from a file, so a mistake in one is a mistake in the program.

      Delimited.Dialect.new!(:tsv)
      Delimited.Dialect.new!(delimiter: ";", newline: "\\r\\n")
      Delimited.Dialect.new!(:fixed, record_length: 100)
  """
  @spec new!(atom() | keyword()) :: t()
  @spec new!(atom() | keyword(), keyword()) :: t()
  def new!(format_or_opts \\ [])
  def new!(format) when is_atom(format), do: new!(format, [])
  def new!(opts) when is_list(opts), do: new!(:csv, opts)

  def new!(format, opts) when is_atom(format) and is_list(opts) do
    merge!(%__MODULE__{}, format_options!(format) ++ opts)
  end

  def new!(opts, more) when is_list(opts) and is_list(more),
    do: new!(:csv, Keyword.merge(opts, more))

  @doc """
  Applies call-site options, or a format name, to an existing dialect.

  A format name applies that format's options over the dialect and leaves the
  rest of it alone, so `merge!(dialect, :tsv)` changes the delimiter without
  disturbing the null strings.

  Raises `ArgumentError` on an unknown format, or an unknown or invalid option.
  """
  @spec merge!(t(), keyword() | atom()) :: t()
  def merge!(%__MODULE__{} = dialect, []), do: dialect

  def merge!(%__MODULE__{} = dialect, format) when is_atom(format) do
    merge!(dialect, format_options!(format))
  end

  def merge!(%__MODULE__{} = dialect, opts) when is_list(opts) do
    opts
    |> Enum.reduce(dialect, fn {key, value}, acc -> put(acc, key, value) end)
    |> validate_bytes!()
  end

  defp put(dialect, :comment, nil), do: %{dialect | comment: nil}
  defp put(dialect, :comment, value), do: %{dialect | comment: byte!(:comment, value)}

  defp put(dialect, :layout, value),
    do: %{dialect | layout: one_of!(:layout, value, [:delimited, :fixed])}

  defp put(dialect, :record_length, value),
    do: %{dialect | record_length: record_length!(value)}

  defp put(dialect, :delimiter, value), do: %{dialect | delimiter: byte!(:delimiter, value)}
  defp put(dialect, :quote_char, value), do: %{dialect | quote_char: byte!(:quote_char, value)}
  defp put(dialect, :headers, value), do: %{dialect | headers: boolean!(:headers, value)}
  defp put(dialect, :trim, value), do: %{dialect | trim: boolean!(:trim, value)}
  defp put(dialect, :bom, value), do: %{dialect | bom: boolean!(:bom, value)}
  defp put(dialect, :null, value), do: %{dialect | null: strings!(:null, value)}
  defp put(dialect, :skip_rows, value), do: %{dialect | skip_rows: count!(:skip_rows, value)}

  defp put(dialect, :chunk_size, value),
    do: %{dialect | chunk_size: positive!(:chunk_size, value)}

  defp put(dialect, :skip_blank_lines, value),
    do: %{dialect | skip_blank_lines: boolean!(:skip_blank_lines, value)}

  defp put(dialect, :escape_formulas, value),
    do: %{dialect | escape_formulas: boolean!(:escape_formulas, value)}

  defp put(dialect, :newline, value),
    do: %{dialect | newline: one_of!(:newline, value, ["\n", "\r\n"])}

  defp put(dialect, :quoting, value),
    do: %{dialect | quoting: one_of!(:quoting, value, [:as_needed, :always])}

  defp put(dialect, :on_missing_header, value),
    do: %{dialect | on_missing_header: one_of!(:on_missing_header, value, [:error, :ignore])}

  defp put(dialect, :on_extra_header, value),
    do: %{dialect | on_extra_header: one_of!(:on_extra_header, value, [:error, :ignore])}

  defp put(_dialect, key, _value) do
    known = %__MODULE__{} |> Map.from_struct() |> Map.keys() |> Enum.sort()

    raise ArgumentError,
          "unknown dialect option #{inspect(key)}. The options are #{inspect(known)}."
  end

  defp validate_bytes!(%__MODULE__{delimiter: same, quote_char: same} = dialect) do
    raise ArgumentError,
          "the delimiter and the quote character are both #{inspect(<<dialect.delimiter>>)}. " <>
            "A cell could not then be told from its own quoting. Change one of them."
  end

  defp validate_bytes!(dialect), do: dialect

  defp byte!(_key, <<byte>>) when byte < 128 and byte not in [?\n, ?\r], do: byte
  defp byte!(_key, byte) when is_integer(byte) and byte < 128 and byte not in [?\n, ?\r], do: byte

  defp byte!(key, value) do
    raise ArgumentError,
          "the #{inspect(key)} must be a single ASCII character other than a line break, " <>
            "given as a one-character string or a codepoint, got: #{inspect(value)}. " <>
            "A multi-byte or multi-character separator is not supported."
  end

  defp record_length!(:line), do: :line
  defp record_length!(value) when is_integer(value) and value > 0, do: value

  defp record_length!(value) do
    raise ArgumentError,
          "the :record_length must be :line, or a positive integer for a file with no " <>
            "line terminators, got: #{inspect(value)}"
  end

  defp boolean!(_key, value) when is_boolean(value), do: value

  defp boolean!(key, value),
    do: raise(ArgumentError, "the #{inspect(key)} must be true or false, got: #{inspect(value)}")

  defp count!(_key, value) when is_integer(value) and value >= 0, do: value

  defp count!(key, value),
    do:
      raise(
        ArgumentError,
        "the #{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
      )

  defp positive!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive!(key, value),
    do:
      raise(
        ArgumentError,
        "the #{inspect(key)} must be a positive integer, got: #{inspect(value)}"
      )

  defp strings!(key, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1) do
      value
    else
      raise ArgumentError,
            "the #{inspect(key)} must be a list of strings, got: #{inspect(value)}"
    end
  end

  defp one_of!(key, value, allowed) when is_list(allowed) do
    if value in allowed do
      value
    else
      raise ArgumentError,
            "the #{inspect(key)} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
    end
  end

  defp format_options!(format) do
    case Keyword.fetch(@formats, format) do
      {:ok, options} -> options
      :error -> raise ArgumentError, "unknown format #{inspect(format)}. #{formats()}"
    end
  end

  defp formats, do: "The formats are #{inspect(Keyword.keys(@formats))}."
end
