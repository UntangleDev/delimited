# Delimited

[![Hex.pm](https://img.shields.io/hexpm/v/delimited.svg)](https://hex.pm/packages/delimited)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/delimited)
[![CI](https://github.com/UntangleDev/delimited/actions/workflows/ci.yml/badge.svg)](https://github.com/UntangleDev/delimited/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/UntangleDev/delimited/blob/main/LICENSE)

Declare the shape of a CSV, TSV, or fixed-width file once, as a struct, and read
and write it through that declaration.

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
row might be malformed, and the exporter owns the column names. The declaration
records that file's shape. The rest of the program can then use dates and
integers. A renamed column fails at the boundary instead of quietly filling a
field with `nil`.

Delimited has no runtime dependencies. `:decimal` is optional, and needed only
for the `:decimal` type.

## Install

```elixir
def deps do
  [
    {:delimited, "~> 0.4"},
    {:decimal, "~> 3.0"}
  ]
end
```

`:decimal` is optional and needed only for the `:decimal` type. Any 2.x or 3.x
version works. Prefer 3.x for files from an untrusted source. It refuses an
absurd number such as `1e1000000000` while reading. Version 2.x accepts the
number and renders it in full while writing. See `Delimited.Type`.

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

A row may be the schema's struct or a map with the same top-level keys. An
embedded key holds the nested struct, map, or list that the schema declares.

Before writing a field, `Delimited` applies the declared read rules to the text
it would emit. It refuses a value if trimming, null handling, padding, a format,
or the field type would change or reject that value. A successfully written row
therefore reads back with the same values. `escape_formulas`, described below,
is the deliberate exception because it changes the text.

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

The field name is the struct key and the header is the file's text, because a
file's column names are the file's business. Renaming a column in the file
changes one `:header`, not every call site.

`Delimited.Field` owns the field options, their defaults, and the fixed-width
padding rules. Read it before declaring null markers, defaults, or read-time
trimming, because those options decide which values the writer can preserve.

## Types

`Delimited.Type` owns the built-in type names and their exact read and write
forms. It also defines the callbacks for a custom type.

A cell must be consumed whole. `"12abc"` is not an integer and `"1.0"` is not an
integer, because a partial read is how silently wrong numbers get into a data
set.

### Dates that are not ISO 8601

`01/03/2024` is the first of March or the third of January depending on who
wrote it, so the schema says which:

```elixir
field :invoiced_on, :date, format: "%d/%m/%Y"
field :due_on, :date, format: ["%m/%d/%Y", "%Y-%m-%d"]
```

The format uses the readable subset of `Calendar.strftime/3` directives, so one
declaration controls reading and writing. `Delimited.Type` owns that subset and
the two-digit-year rule. Give a list to read several spellings; the writer uses
the first. The schema compiler rejects a directive that cannot be read back and
a format that does not state every component its type needs.

A two-digit `%y` uses the POSIX window: 69-99 are the 1900s, 00-68 the 2000s.

No built-in type parses a thousands separator or a currency symbol. Declare a
type for those:

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

The callbacks must be inverses for every value the type writes. Before emitting
a field, the writer applies the field's read transformations to the dumped text
and calls `cast/2`. It refuses the value unless `cast/2` returns the same term.

## Repeated groups of columns

A file that carries `billing_street`, `billing_city`, `shipping_street`, and
`shipping_city` is carrying one group twice. Declare it once:

```elixir
defmodule Address do
  use Delimited.Schema

  delimited_schema do
    field :street, :string
    field :city, :string
  end
end

defmodule Order do
  use Delimited.Schema

  delimited_schema do
    field :id, :integer
    embeds_one :billing, Address, prefix: "billing_"
    embeds_one :shipping, Address, prefix: "shipping_"
    embeds_many :lines, LineItem, count: 2, prefix: "item_{n}_"
  end
end

Delimited.read(Order, "orders.csv")
#=> [%Order{id: 1,
#           billing:  %Address{street: "1 High St", city: "Leeds"},
#           shipping: nil,
#           lines: [%LineItem{sku: "A-1", qty: 3}, nil]}]
```

The point is not brevity. Two copies of a column list drift apart, and the way
they drift is `shipping_postcode` quietly reading the billing one. Declared
once, they cannot.

`embeds_many` needs a `:count`, because a row holds a fixed number of columns,
and a `{n}` in its prefix to tell the copies apart. A list may contain fewer
copies; the writer leaves the remaining groups blank. A longer list is an error
because the declared row has nowhere to put it.

**A group whose every column is empty reads as `nil`**, and `nil` writes its
columns back empty — the same rule the fixed layout uses for a blank field. One
column filled makes the group present. `required: true` makes an absent group an
error instead.

Under the fixed layout there are no headers to prefix, so an embed says where
its bytes start and the embedded schema's own positions are counted from there:

```elixir
delimited_schema :fixed do
  field :record_type, :string, at: 1..1
  embeds_one :payer, Party, at: 2      # Party's 1..6 and 7..14 land at 2..7, 8..15
  embeds_one :payee, Party, at: 16     # and again at 16..21, 22..29
end
```

Repeated blocks follow one another by the embedded schema's own width, or by a
declared `:stride` where the file leaves a gap between them.

## Fixed-width files

A file with no delimiters at all — where a field is a range of bytes — is the
same declaration with positions on it:

```elixir
defmodule Payment do
  use Delimited.Schema

  delimited_schema :fixed do
    field :record_type, :string, at: 1..1
    field :account, :string, at: 2..9
    # positions 10 and 11 are filler, so no field declares them
    field :amount, :integer, at: 12..19, pad: ?0
    field :name, :string, at: 20..37
    field :active, {:enum, [true: "1", false: "0"]}, at: 38..38
  end
end

Delimited.read(Payment, "payments.txt")
```

Positions are **1-based and inclusive**, the way a file specification writes
them: a field documented as "positions 12-19" is `at: 12..19`. Each field
carries its own, so a position transcribed wrongly affects that field alone
rather than shifting every field after it, and so a gap needs no declaration.

`:align` and `:pad` say how a value sits in its field. The defaults are what
specifications almost always mean: numbers to the right, everything else to the
left, padded with spaces.

### Blank, zero, and the difference between them

The one place fixed-width files bite is an empty field, so it is worth stating
what this does:

| In the file | `at: 12..19, pad: ?0` reads |
|---|---|
| `00001234` | `1234` |
| `00000000` | `0` |
| `        ` | `nil` |

An all-zeros field states zero and reads as zero. The same field left blank says
"no value" and reads as `nil`. Writing does the same in reverse: `nil` is
written blank whatever the field's `:pad`, because filling an empty field with
zeros would state a number the row never held. For an optional field with a
`nil` default, `nil` therefore survives a round trip.

### Records with no line terminators

A mainframe extract is often one long byte stream cut every N bytes. Say so:

```elixir
delimited_schema :fixed, record_length: 100 do
```

`record_length: N` is only for a file with no terminators. If a file has line
terminators, they frame its records regardless of this option. A terminator is
therefore never part of a record.

### What a fixed-width schema will not do

* **Positions are byte offsets, not character offsets.** These formats are
  ASCII, where the two are the same. A field whose bytes are not valid UTF-8 is
  an `:invalid_encoding` error rather than a silently mangled string, since that
  is what counting characters instead of bytes produces.
* **A record shorter than a declared field** is a `:record_too_short` error.
  Bytes *beyond* the last declared field are filler and are ignored, the same
  way an undeclared extra column is.
* **A value wider than its field** is a `:value_too_wide` error when writing.
  Truncating would produce a file that parses and lies.
* **Filler is not preserved.** Nothing reads the bytes no field declares, so
  nothing can write them back; they are written blank.
* `:boolean` writes `"true"` and `"false"`, so a one-character flag column wants
  `{:enum, [true: "Y", false: "N"]}`.

## Dialects

A schema declares the layout and punctuation of the file it was written for.
A call may override punctuation and other runtime options, but it may not change
the layout. The layout determines field positions and embedded shapes when the
schema compiles.

```elixir
delimited_schema :tsv, headers: false do
  field :sku, :string
end

Delimited.read(Product, "supplier.csv", delimiter: ",", headers: true)
```

`Delimited.Dialect` owns the format names, options, defaults, and restrictions.
Its documentation also explains the cases that change framing rather than cell
casting. For example, a comment is removed before the parser reads any cell, so
a commented line may contain an unclosed quote.

With a header row, the schema ignores undeclared columns by default and rejects
a missing declared column. Without a header row, no name identifies an extra
column. Each row must therefore contain exactly the declared number of cells.

## What it will not read

Some things are refused rather than guessed at, so that a wrong answer cannot be
delivered confidently:

* **A multi-character or non-ASCII delimiter.** The parser decides on single
  bytes.
* **A delimited row whose length differs from the header row.** Without headers,
  the row must match the schema's declared field count. A short row is an error,
  not a row padded with `nil`.
* **A fixed-width record shorter than a declared field.** The field is absent,
  so the reader returns `:record_too_short` instead of guessing its bytes.
* **A locale-specific number.** A thousands separator or currency symbol needs
  a custom `Delimited.Type`. A date can instead declare a field `:format`.
* **Invalid UTF-8 in a fixed-width field.** The delimited parser is byte-oriented
  and passes other encodings through unchanged to a `:string` field. The fixed
  layout refuses invalid UTF-8 because it usually means that the positions or
  encoding are wrong.

## Formula injection

Some spreadsheet import paths interpret a cell that starts with formula syntax
as a formula. A malicious formula can disclose data or invoke an external
action when the spreadsheet permits one.

`escape_formulas: true` adds an apostrophe before the formula syntax. The option
is off by default because it changes the data. Use it only after testing the
target program's complete import and save path:

```elixir
Delimited.write(Export, path, rows, escape_formulas: true)
```

This option is not a universal spreadsheet defence. `Delimited.Dialect` owns
the exact leader set, the reason for the opt-in default, and the known gaps in
the defence. Importing the file as text remains the reliable control.

## Development

```console
nix develop      # or: direnv allow
mix deps.get
mix test
```

## Benchmarks

```console
mix run bench/read.exs
```

Each script under `bench/` answers one question. The suite measures:

* reading, with parsing and casting shown separately;
* parser cost per byte and per cell;
* writing under each quoting policy;
* result growth when `read/3` collects rows and a stream consumer discards them;
* the effect of `:chunk_size`; and
* the cost of declared features.

See [bench/README.md](bench/README.md) for the results and their limits.

The full check, which is what continuous integration runs:

```console
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
for benchmark in bench/*.exs; do
  BENCH_TIME=0 BENCH_WARMUP=0 BENCH_ROWS=100 mix run "$benchmark"
done
mix dialyzer
mix docs --warnings-as-errors
mix hex.build
```

## Licence

MIT. See [LICENSE](LICENSE).
