Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.Write do
  @moduledoc false

  # What does writing cost, and what does quoting cost within it?
  #
  # `:as_needed` scans every cell for a delimiter, a quote, or a line break;
  # `:always` skips the scan and quotes regardless. The comparison measures the
  # total cost of each policy. It does not isolate the scan because `:always`
  # also changes the output and escapes every cell.

  alias Delimited.Bench.Fixture
  alias Delimited.Bench.FixedRow
  alias Delimited.Bench.Row

  @spec run() :: Benchee.Suite.t()
  def run do
    typed = Delimited.decode!(Row, Fixture.plain_csv())
    quoted = Delimited.decode!(Row, Fixture.quoted_csv())
    fixed = Delimited.decode!(FixedRow, Fixture.fixed_file())

    IO.puts("#{length(typed)} rows\n")

    Benchee.run(
      %{
        "encode, quoting as needed" => fn rows -> encode(Row, rows, []) end,
        "encode, quoting always" => fn rows -> encode(Row, rows, quoting: :always) end
      },
      Fixture.options("write-quoting",
        inputs: %{"plain values" => typed, "values needing quotes" => quoted}
      )
    )

    IO.puts("\nAgainst the fixed layout, which pads rather than quotes.\n")

    Benchee.run(
      %{
        "encode fixed" => fn -> encode(FixedRow, fixed, []) end,
        "encode delimited" => fn -> encode(Row, typed, []) end
      },
      Fixture.options("write-layout")
    )
  end

  defp encode(schema, rows, opts) do
    schema |> Delimited.encode!(rows, opts) |> Enum.to_list() |> IO.iodata_to_binary()
  end
end

Delimited.Bench.Write.run()
