defmodule Delimited.FormatTest do
  use ExUnit.Case, async: true

  alias Delimited.Error

  defmodule Invoice do
    @moduledoc false

    use Delimited.Schema

    delimited_schema do
      field :uk, :date, format: "%d/%m/%Y"
      field :us, :date, format: "%m/%d/%Y"
      field :compact, :date, format: "%Y%m%d"
      field :named, :date, format: "%d %B %Y"
      field :short, :date, format: "%d-%b-%y"
      field :either, :date, format: ["%d/%m/%Y", "%Y-%m-%d"]
      field :at, :time, format: "%H:%M"
      field :stamp, :naive_datetime, format: "%Y-%m-%d %H:%M:%S"
      field :recorded, :utc_datetime, format: "%Y-%m-%d %H:%M:%S"
    end
  end

  @headers "uk,us,compact,named,short,either,at,stamp,recorded\n"

  describe "reading" do
    test "reads the same digits differently as the format says" do
      assert %{uk: ~D[2024-03-01], us: ~D[2024-03-01]} =
               row("01/03/2024,03/01/2024,,,,,,,")
    end

    test "reads a format with no separators" do
      assert %{compact: ~D[2024-03-01]} = row(",,20240301,,,,,,")
    end

    test "reads a month by name, in any case" do
      assert %{named: ~D[2024-03-01]} = row(",,,1 March 2024,,,,,")
      assert %{named: ~D[2024-03-01]} = row(",,,01 march 2024,,,,,")
    end

    test "reads an abbreviated month name" do
      assert %{short: ~D[2024-03-01]} = row(",,,,01-Mar-24,,,,")
    end

    test "reads an unpadded number where a separator follows it" do
      assert %{uk: ~D[2024-03-01]} = row("1/3/2024,,,,,,,,")
    end

    test "tries each declared format in turn" do
      assert %{either: ~D[2024-03-01]} = row(",,,,,01/03/2024,,,")
      assert %{either: ~D[2024-03-01]} = row(",,,,,2024-03-01,,,")
    end

    test "reads times and datetimes" do
      assert %{at: ~T[09:30:00], stamp: ~N[2024-03-01 09:30:00]} =
               row(",,,,,,09:30,2024-03-01 09:30:00,")
    end

    test "reads a datetime with a format as UTC" do
      assert %{recorded: ~U[2024-03-01 09:30:00Z]} = row(",,,,,,,,2024-03-01 09:30:00")
    end

    test "refuses a date that does not exist" do
      assert {:error, [%Error{reason: :cast_failed, field: :uk} = error]} =
               decode("31/02/2024,,,,,,,,")

      assert Exception.message(error) =~ ~s(cannot read "31/02/2024" as a date or time written)
    end

    test "names every format it tried" do
      assert {:error, [error]} = decode(",,,,,nope,,,")

      assert Exception.message(error) =~ ~s(written "%d/%m/%Y", or "%Y-%m-%d")
    end

    test "refuses text the format does not account for" do
      assert {:error, [%Error{field: :uk}]} = decode("01/03/2024 (approx),,,,,,,,")
    end

    test "a declared format replaces ISO 8601 rather than adding to it" do
      assert {:error, [%Error{field: :uk}]} = decode("2024-03-01,,,,,,,,")
    end
  end

  describe "the two-digit year window" do
    test "reads 69 and above as the twentieth century" do
      assert %{short: ~D[1969-06-15]} = row(",,,,15-Jun-69,,,,")
      assert %{short: ~D[1999-06-15]} = row(",,,,15-Jun-99,,,,")
    end

    test "reads 68 and below as the twenty-first" do
      assert %{short: ~D[2068-06-15]} = row(",,,,15-Jun-68,,,,")
      assert %{short: ~D[2000-06-15]} = row(",,,,15-Jun-00,,,,")
    end
  end

  describe "writing" do
    test "writes each field in its own format" do
      assert encode(uk: ~D[2024-03-01], us: ~D[2024-03-01], compact: ~D[2024-03-01]) =~
               "\n01/03/2024,03/01/2024,20240301,"
    end

    test "writes a month name" do
      assert encode(named: ~D[2024-03-01]) =~ ",01 March 2024,"
    end

    test "writes the first format when several are declared" do
      assert encode(either: ~D[2024-03-01]) =~ ",01/03/2024,"
    end

    test "round-trips every format" do
      rows = [
        %Invoice{
          uk: ~D[2024-03-01],
          us: ~D[2024-12-25],
          compact: ~D[1999-01-02],
          named: ~D[2024-03-01],
          short: ~D[2024-03-01],
          either: ~D[2024-03-01],
          at: ~T[09:30:00],
          stamp: ~N[2024-03-01 09:30:00],
          recorded: ~U[2024-03-01 09:30:00Z]
        }
      ]

      written = Invoice |> Delimited.encode!(rows) |> Enum.to_list() |> IO.iodata_to_binary()

      assert Delimited.decode!(Invoice, written) == rows
    end
  end

  describe "declaration errors" do
    test "refuses a directive that cannot be read back" do
      assert_raise ArgumentError, ~r/uses %A, which cannot be read back/, fn ->
        defmodule Weekday do
          use Delimited.Schema

          delimited_schema do
            field :d, :date, format: "%A %d/%m/%Y"
          end
        end
      end
    end

    test "refuses a format that cannot supply what the type needs" do
      assert_raise ArgumentError, ~r/never says the day, which :date needs/, fn ->
        defmodule Incomplete do
          use Delimited.Schema

          delimited_schema do
            field :d, :date, format: "%Y-%m"
          end
        end
      end
    end

    test "refuses a format on a type that has no format" do
      assert_raise ArgumentError, ~r/only \[:date, :time, :naive_datetime, :utc_datetime\]/, fn ->
        defmodule Numeric do
          use Delimited.Schema

          delimited_schema do
            field :n, :integer, format: "%Y"
          end
        end
      end
    end
  end

  defp decode(cells), do: Delimited.decode(Invoice, @headers <> cells <> "\n")

  defp row(cells) do
    {:ok, [row]} = decode(cells)
    row
  end

  defp encode(fields) do
    Invoice
    |> Delimited.encode!([struct!(Invoice, fields)])
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end
end
