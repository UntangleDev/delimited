# Delimited

[![Hex.pm](https://img.shields.io/hexpm/v/delimited.svg)](https://hex.pm/packages/delimited)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/delimited)
[![CI](https://github.com/UntangleDev/delimited/actions/workflows/ci.yml/badge.svg)](https://github.com/UntangleDev/delimited/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/UntangleDev/delimited/blob/main/LICENSE)

Declare the shape of a CSV or TSV file once, as a struct, and read and write it
through that declaration.

```elixir
defmodule Employee do
  use Delimited.Schema

  delimited_schema do
    field :id, :integer, header: "Employee ID"
    field :name, :string, required: true
    field :department, {:enum, [engineering: "ENG", sales: "SLS"]}
    field :hired_on, :date, header: "Hire Date"
    field :salary, :decimal
    field :active, :boolean, default: true
  end
end

{:ok, employees} = Delimited.read(Employee, "employees.csv")
#=> [%Employee{id: 1, name: "Lovelace, Ada", department: :engineering,
#              hired_on: ~D[1843-01-01], salary: Decimal.new("1200.50"), active: true}]

:ok = Delimited.write(Employee, "employees.tsv", employees, :tsv)
```

The schema plays the part `Ecto.Schema` plays for a table, and `Delimited` plays
the part of the repository. A schema declares columns and holds no behaviour of
its own.

## What it is for

A file arrives from somewhere you do not control. Every column is text, every
row might be malformed, and the columns are named by whoever exported them. The
declaration above is where that file's shape is written down, so that the rest
of the program can work with dates and integers, and so that a renamed column
fails in one obvious place instead of quietly filling a field with `nil`.

Delimited has no runtime dependencies. `:decimal` is optional, and needed only
for the `:decimal` type.

## Install

```elixir
def deps do
  [
    {:delimited, "~> 0.1"},
    {:decimal, "~> 3.0"}
  ]
end
```

`:decimal` is optional and needed only for the `:decimal` type. Any 2.x or 3.x
version works. Prefer 3.x when the files come from anywhere you do not trust:
it refuses an absurd number such as `1e1000000000` as it reads it, where 2.x
accepts one and renders it in full on the way back out. See `Delimited.Type`.

## Reading

| You have | You want | Use |
|---|---|---|
| a path | every row, or the errors | `Delimited.read/3` |
| a path | every row, or an exception | `Delimited.read!/3` |
| a path, or a stream of slices | rows as they arrive | `Delimited.stream/3` |
| a binary in memory | every row, or the errors | `Delimited.decode/3` |

`read/3` returns `{:ok, rows}` or `{:error, errors}`, where the errors are every
error in the file rather than only the first. One unreadable cell fails its own
row and leaves the rest alone, so the error list is where to look for what a
supplier keeps getting wrong.

```elixir
case Delimited.read(Employee, "employees.csv") do
  {:ok, employees} -> employees
  {:error, errors} -> Enum.each(errors, &Logger.warning(Exception.message(&1)))
end
```

`stream/3` holds one slice and one row at a time, for a file larger than the
memory you want to spend on it:

```elixir
Employee
|> Delimited.stream("employees.csv")
|> Stream.filter(&match?({:ok, _row}, &1))
|> Stream.chunk_every(1000)
|> Enum.each(fn chunk -> insert_all(chunk) end)
```

It also reads anything already arriving in pieces, such as an upload or a
decompressed response body, if you give it an enumerable of binaries instead of
a path.

## Writing

```elixir
:ok = Delimited.write(Employee, "employees.csv", employees)
```

A row may be the schema's struct, or any map holding a key for every declared
field. Writing is the inverse of reading: whatever `Delimited` writes, it reads
back unchanged, for every value and every dialect. The one exception is
`escape_formulas`, described below, which changes the text deliberately.

`encode!/3` returns a lazy stream of iodata, for an export that should never
exist in memory all at once:

```elixir
Employee
|> Delimited.encode!(Repo.stream(query))
|> Enum.into(File.stream!("employees.csv"))
```

## Errors

Every failure is a `Delimited.Error` holding a `:reason` to match on, a message
to show a human, and as much of the path, line, column, and field as the failure
knows.

```
employees.csv, line 4, column 4, field :hired_on: cannot read "01/03/2024" as a
date in ISO 8601 form (YYYY-MM-DD). Correct the value, or declare the field with
a type that accepts it.
```

A parse failure ends the file: after a misplaced quote, no later row can be
trusted. A cast failure fails only its own row.

## Fields

```elixir
field :hired_on, :date, header: "Hire Date", required: true
```

| Option | Meaning |
|---|---|
| `:header` | the column name in the file. Defaults to the field name |
| `:default` | the value for an empty cell. Defaults to `nil` |
| `:required` | an empty cell is an error rather than `nil` |
| `:trim` | strip surrounding whitespace before reading |
| `:null` | the strings that mean "no value" for this field |

The field name is the struct key and the header is the file's text, because a
file's column names are the file's business. Renaming a column in the file
changes one `:header`, not every call site.

## Types

`:string`, `:integer`, `:float`, `:boolean`, `:date`, `:time`,
`:naive_datetime`, `:utc_datetime`, `:decimal`, and `{:enum, values}`.

A cell must be consumed whole. `"12abc"` is not an integer and `"1.0"` is not an
integer, because a partial read is how silently wrong numbers get into a data
set. No built-in type parses a locale-specific date, a thousands separator, or a
currency symbol. Declare a type for those:

```elixir
defmodule Pence do
  @behaviour Delimited.Type

  @impl true
  def cast("£" <> amount, _opts) do
    case Float.parse(amount) do
      {pounds, ""} -> {:ok, round(pounds * 100)}
      _other -> {:error, "an amount in pounds"}
    end
  end

  def cast(_text, _opts), do: {:error, "an amount in pounds"}

  @impl true
  def dump(pence, _opts) when is_integer(pence) do
    penny = pence |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    {:ok, ["£", Integer.to_string(div(pence, 100)), ".", penny]}
  end

  def dump(_other, _opts), do: {:error, "an amount in pounds"}
end
```

Use it as `field :salary, Pence`. The error string completes the sentence
"cannot read _value_ as ...", so write a noun phrase. Options a field does not
recognise are passed on to the type, so `field :salary, Pence, symbol: "$"`
reaches `cast/2` as `[symbol: "$"]`.

## Dialects

A schema declares the punctuation of the file it was written for, and any call
can override it:

```elixir
delimited_schema :tsv, headers: false do
  field :sku, :string
end

Delimited.read(Product, "supplier.csv", delimiter: ",", headers: true)
```

`Delimited.Dialect` documents every option. The ones worth knowing before the
first surprise:

* **`headers` defaults to `true`.** With `headers: false`, columns are matched
  by declaration order.
* **A column the file holds and the schema does not declare is ignored.** A
  column the schema declares and the file does not hold is an error, because
  that is the shape a renamed column takes.
* **`trim` defaults to `false`**, so a value is read exactly as the file holds
  it. Set `trim: true` for the export that pads its columns.
* **A byte order mark is stripped when reading**, and written only with
  `bom: true`, which is what Excel needs in order to read UTF-8.
* **`skip_rows`** discards rows before the header row, for the export that
  begins with a title.

## What it will not read

Some things are refused rather than guessed at, so that a wrong answer cannot be
delivered confidently:

* **A multi-character or non-ASCII delimiter.** The parser decides on single
  bytes.
* **A fixed-width file.** There are no delimiters to find.
* **A row of a different length to the header row.** A short row is an error,
  not a row padded with `nil`.
* **A locale-specific number or date.** `1.234,56` and `01/03/2024` cannot be
  read without knowing where the file came from. Declare a type that knows.
* **An encoding that is not UTF-8.** The parser works on bytes, so another
  encoding passes through unchanged and lands in your `:string` fields as
  whatever it was. Convert the file first.

## Formula injection

A cell beginning with `=`, `+`, `-`, `@`, a tab, or a carriage return is
executed as a formula by Excel, LibreOffice, and Google Sheets when the file is
opened. A file assembled from untrusted input can therefore run a command on the
reader's machine.

`escape_formulas: true` prefixes such a cell with an apostrophe. It is **off by
default** because it changes the data: a file written with it and read back
yields `'=SUM(A1)`, not `=SUM(A1)`. Correctness of the round trip wins over a
defence against a hazard in a different program, and the choice is stated here
rather than made silently.

Turn it on when writing a file that a person will open in a spreadsheet:

```elixir
Delimited.write(Export, path, rows, escape_formulas: true)
```

A value that reads as a number is never prefixed, so `-1.5` survives. The
defence covers the leading character only. It is no substitute for the consumer
opening the file as data rather than as a spreadsheet.

## Development

```console
nix develop      # or: direnv allow
mix deps.get
mix test
```

The full check, which is what continuous integration runs:

```console
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix docs --warnings-as-errors
mix hex.build
```

## Licence

MIT. See [LICENSE](LICENSE).
