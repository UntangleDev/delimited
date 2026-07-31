Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.ParserShape do
  @moduledoc false

  # Where does the parser's time actually go?
  #
  # Three questions, each of which changes what an optimisation should touch:
  #
  #   * How far is it from the floor? "naive split" is `:binary.split/3` twice,
  #     which is not a parser — it cannot quote, cannot resume across slices,
  #     tracks no line numbers, and would read a quoted cell wrongly. It is here
  #     only as the fastest thing that could possibly produce cells, so that the
  #     gap is a number rather than a feeling.
  #
  #   * Is the cost per byte or per cell? Both files below hold the same bytes
  #     and differ only in how many cells those bytes are divided into. If the
  #     wide one is much slower, the scanning is cheap and the per-cell work is
  #     what to look at.
  #
  #   * What does quoting cost? A quoted cell takes a second scanning path and
  #     one more state transition per cell.

  alias Delimited.Bench.Fixture
  alias Delimited.Dialect
  alias Delimited.Parser

  @rows 8_000
  @width 8
  @cell 20

  def run do
    dialect = Dialect.new!()
    plain = Fixture.plain_csv()

    IO.puts("Against the fastest thing that could produce cells at all\n")

    Benchee.run(
      %{
        "naive split, not a parser" => fn -> naive(plain) end,
        "Delimited.Parser" => fn -> parse(plain, dialect) end
      },
      Fixture.options()
    )

    IO.puts("\nThe same bytes, divided into different numbers of cells\n")

    Benchee.run(
      %{
        "#{@width} cells per row" => fn -> parse(wide(), dialect) end,
        "1 cell per row" => fn -> parse(narrow(), dialect) end
      },
      Fixture.options()
    )

    IO.puts("\nQuoted cells against plain ones\n")

    Benchee.run(
      %{
        "plain" => fn -> parse(plain, dialect) end,
        "quoted" => fn -> parse(Fixture.quoted_csv(), dialect) end
      },
      Fixture.options()
    )
  end

  defp parse(input, dialect), do: [input] |> Parser.stream(dialect) |> Stream.run()

  defp naive(input) do
    input
    |> :binary.split("\n", [:global])
    |> Enum.map(&:binary.split(&1, ",", [:global]))
  end

  defp wide do
    cell = String.duplicate("x", @cell)
    row = Enum.join(List.duplicate(cell, @width), ",")

    IO.iodata_to_binary(for _ <- 1..@rows, do: [row, "\n"])
  end

  defp narrow do
    row = String.duplicate("x", @width * @cell + @width - 1)

    IO.iodata_to_binary(for _ <- 1..@rows, do: [row, "\n"])
  end
end

Delimited.Bench.ParserShape.run()
