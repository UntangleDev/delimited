Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.Overhead do
  @moduledoc false

  # What does each declared feature cost, and does one that should cost nothing
  # actually cost nothing?
  #
  # Two of these guard a claim made in the documentation rather than hunting for
  # a saving:
  #
  #   * `Delimited.Embed` says an embed is expanded when the schema compiles, so
  #     reading through embeds should cost what reading the same columns flat
  #     costs. A gap here means the expansion is not doing what it claims.
  #   * `Delimited.Strftime` says a format is compiled once, so reading a
  #     declared format should be near reading ISO 8601. It cannot be faster:
  #     `Date.from_iso8601/1` is a tighter parser than a directive walk.
  #
  # `:trim` and `:comment` are ordinary options, measured so that anyone turning
  # one on knows what they are paying.

  alias Delimited.Bench.Embedded
  alias Delimited.Bench.Fixture
  alias Delimited.Bench.Flat
  alias Delimited.Bench.FormattedDates
  alias Delimited.Bench.IsoDates
  alias Delimited.Bench.Row

  def run do
    plain = Fixture.plain_csv()

    IO.puts("Embeds against the same columns declared flat\n")

    Benchee.run(
      %{
        "flat columns" => fn -> Delimited.decode!(Flat, addresses()) end,
        "through embeds" => fn -> Delimited.decode!(Embedded, addresses()) end
      },
      Fixture.options()
    )

    IO.puts("\nA declared date format against ISO 8601\n")

    Benchee.run(
      %{
        "ISO 8601" => fn -> Delimited.decode!(IsoDates, iso_dates()) end,
        "declared format" => fn -> Delimited.decode!(FormattedDates, formatted_dates()) end
      },
      Fixture.options()
    )

    IO.puts("\nOptions that do extra work per cell or per line\n")

    Benchee.run(
      %{
        "plain" => fn -> Delimited.decode!(Row, plain) end,
        "trim: true" => fn -> Delimited.decode!(Row, plain, trim: true) end,
        "comment: \"#\"" => fn -> Delimited.decode!(Row, plain, comment: "#") end
      },
      Fixture.options()
    )
  end

  defp addresses do
    rows =
      Enum.map(1..Fixture.rows(), fn index ->
        "#{index},#{index} High St,Leeds,#{index} Low Rd,York\n"
      end)

    IO.iodata_to_binary([
      "id,billing_street,billing_city,shipping_street,shipping_city\n",
      rows
    ])
  end

  defp iso_dates do
    rows =
      Enum.map(1..Fixture.rows(), fn index ->
        date = Date.add(~D[2020-01-01], rem(index, 1500))
        iso = Date.to_iso8601(date)
        [iso, ",", iso, ",", iso, "\n"]
      end)

    IO.iodata_to_binary(["a,b,c\n", rows])
  end

  defp formatted_dates do
    rows =
      Enum.map(1..Fixture.rows(), fn index ->
        text = ~D[2020-01-01] |> Date.add(rem(index, 1500)) |> Calendar.strftime("%d/%m/%Y")
        [text, ",", text, ",", text, "\n"]
      end)

    IO.iodata_to_binary(["a,b,c\n", rows])
  end
end

Delimited.Bench.Overhead.run()
