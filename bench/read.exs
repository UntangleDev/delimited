Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.Read do
  @moduledoc false

  # What does reading a file cost, and which half of it costs that?
  #
  # "parse only" runs the delimiter state machine and stops, without a schema.
  # "read as text" adds header matching and a schema whose every field is
  # `:string`, so it casts nothing. "read as typed" adds the types. The
  # difference between each pair is what that step costs, which is the number to
  # look at before optimising either one.

  alias Delimited.Bench.Fixture
  alias Delimited.Bench.Row
  alias Delimited.Bench.TextRow
  alias Delimited.Dialect
  alias Delimited.Parser

  def run do
    plain = Fixture.plain_csv()
    quoted = Fixture.quoted_csv()
    fixed = Fixture.fixed_file()
    csv = Dialect.new!()

    IO.puts("#{Fixture.rows()} rows, #{div(byte_size(plain), 1024)} KiB plain\n")

    Benchee.run(
      %{
        "parse only" => fn input -> input |> parse(csv) |> Stream.run() end,
        "read as text" => fn input -> Delimited.decode!(TextRow, input) end,
        "read as typed" => fn input -> Delimited.decode!(Row, input) end
      },
      Fixture.options(inputs: %{"plain" => plain, "quoted" => quoted})
    )

    IO.puts("\nThe fixed layout has no delimiters to find, and takes each field")
    IO.puts("from a byte range, so it is measured on its own file.\n")

    Benchee.run(
      %{
        "fixed, typed" => fn -> Delimited.decode!(Delimited.Bench.FixedRow, fixed) end,
        "delimited, typed" => fn -> Delimited.decode!(Row, plain) end
      },
      Fixture.options()
    )
  end

  defp parse(input, dialect), do: Parser.stream([input], dialect)
end

Delimited.Bench.Read.run()
