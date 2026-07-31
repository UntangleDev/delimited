defmodule Delimited.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Delimited.Dialect
  alias Delimited.Encoder
  alias Delimited.Parser
  alias Delimited.Test.Employee

  # Characters chosen to land on the parser's decisions rather than around them:
  # the delimiter, the quote, both line breaks, and text on either side.
  @awkward ["a", "é", " ", ",", "\t", "\"", "\n", "\r", "\r\n", "'", "="]

  property "every row survives being written and read back" do
    check all(rows <- rows(), dialect <- dialect()) do
      encoded =
        rows
        |> Enum.map(&Encoder.row(&1, dialect))
        |> IO.iodata_to_binary()

      assert parse(encoded, dialect) == rows
    end
  end

  property "where the slices fall does not change what is read" do
    check all(rows <- rows(), size <- integer(1..8)) do
      dialect = Dialect.new!()
      encoded = rows |> Enum.map(&Encoder.row(&1, dialect)) |> IO.iodata_to_binary()

      assert parse_in_slices(encoded, size, dialect) == rows
    end
  end

  property "every schema value survives being written and read back" do
    check all(employees <- list_of(employee(), max_length: 10)) do
      encoded =
        Employee |> Delimited.encode!(employees) |> Enum.to_list() |> IO.iodata_to_binary()

      assert Delimited.decode!(Employee, encoded) == employees
    end
  end

  defp rows do
    gen all(
          width <- integer(1..4),
          rows <- list_of(list_of(cell(), length: width), max_length: 5)
        ) do
      rows
    end
  end

  defp cell do
    @awkward
    |> member_of()
    |> list_of(max_length: 4)
    |> map(&Enum.join/1)
  end

  defp dialect do
    gen all(
          delimiter <- member_of([",", "\t", ";", "|"]),
          quote_char <- member_of(["\"", "'"]),
          newline <- member_of(["\n", "\r\n"]),
          quoting <- member_of([:as_needed, :always])
        ) do
      Dialect.new!(
        delimiter: delimiter,
        quote_char: quote_char,
        newline: newline,
        quoting: quoting
      )
    end
  end

  defp employee do
    gen all(
          id <- one_of([nil, integer()]),
          name <- filter(cell(), &(&1 != "")),
          department <- member_of([nil, :engineering, :sales]),
          hired_on <- one_of([nil, hire_date()]),
          salary <- one_of([nil, integer(0..1_000_000)]),
          active <- boolean()
        ) do
      %Employee{
        id: id,
        name: name,
        department: department,
        hired_on: hired_on,
        salary: salary,
        active: active
      }
    end
  end

  defp hire_date do
    map(integer(0..40_000), &Date.add(~D[1900-01-01], &1))
  end

  defp parse(encoded, dialect), do: parse_slices([encoded], dialect)

  defp parse_in_slices(encoded, size, dialect) do
    encoded
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
    |> parse_slices(dialect)
  end

  defp parse_slices(slices, dialect) do
    slices
    |> Parser.stream(dialect)
    |> Enum.map(fn {:ok, {_line, cells}} -> cells end)
  end
end
