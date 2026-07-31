defmodule Delimited.FixedLayoutTest do
  use ExUnit.Case, async: true

  alias Delimited.Error
  alias Delimited.Test.Block
  alias Delimited.Test.Padded
  alias Delimited.Test.Payment

  #     1|2------9|10|12----19|20--------------37|38
  @ada "6" <> "12345678" <> "  " <> "00001234" <> "Lovelace, Ada     " <> "1"
  @grace "6" <> "87654321" <> "XX" <> "00000000" <> "Hopper            " <> "0"
  @blank "6" <> "        " <> "  " <> "        " <> "                  " <> " "

  describe "reading" do
    test "takes each field from its declared bytes" do
      assert {:ok, [ada]} = Delimited.decode(Payment, @ada <> "\n")

      assert ada == %Payment{
               record_type: "6",
               account: "12345678",
               amount: 1234,
               name: "Lovelace, Ada",
               active: true
             }
    end

    test "ignores bytes no field declares" do
      assert {:ok, [grace]} = Delimited.decode(Payment, @grace <> "\n")

      assert grace.account == "87654321"
      assert grace.amount == 0
    end

    test "ignores bytes beyond the last declared field" do
      assert {:ok, [ada]} = Delimited.decode(Payment, @ada <> "trailing filler\n")

      assert ada.active == true
    end

    test "reads an all-blank record as no values at all" do
      assert {:ok, [%Payment{} = blank]} = Delimited.decode(Payment, @blank <> "\n")

      assert blank == %Payment{record_type: "6"}
    end

    test "reads an all-zeros field as zero rather than as no value" do
      assert {:ok, [grace]} = Delimited.decode(Payment, @grace <> "\n")

      assert grace.amount == 0
      refute grace.amount == nil
    end

    test "strips padding from the padded side only" do
      record = "6" <> "12345678" <> "  " <> "00001234" <> "  spaced both     " <> "1"

      assert {:ok, [row]} = Delimited.decode(Payment, record <> "\n")
      assert row.name == "  spaced both"
    end

    test "reports a record that ends before a declared field" do
      assert {:error, [%Error{reason: :record_too_short, line: 1, detail: {38, 9}} = error]} =
               Delimited.decode(Payment, "612345678\n")

      assert Exception.message(error) =~ "the record holds 9 bytes where 38 are expected"
    end

    test "reports bytes that are not valid UTF-8, which is what miscounting produces" do
      record = "6" <> "1234567é" <> "  " <> "00001234" <> "x                 " <> "1"

      assert {:error, [error | _rest]} = Delimited.decode(Payment, record <> "\n")

      assert %Error{reason: :invalid_encoding, field: :account, column: 2} = error
      assert Exception.message(error) =~ "not valid UTF-8"
    end

    test "locates an error at the field's first byte" do
      record = "6" <> "12345678" <> "  " <> "0000123x" <> "Name              " <> "1"

      assert {:error, [%Error{reason: :cast_failed, field: :amount, column: 12, line: 1}]} =
               Delimited.decode(Payment, record <> "\n")
    end

    test "reads a file of fixed-length blocks" do
      assert {:ok, [first, second]} =
               Delimited.decode(Block, "AB1200000042" <> "CD3400000007")

      assert first == %Block{code: "AB12", quantity: 42}
      assert second == %Block{code: "CD34", quantity: 7}
    end

    test "skips a header line when told the file has one" do
      assert {:ok, [%Payment{account: "12345678"}]} =
               Delimited.decode(Payment, "a header line\n" <> @ada <> "\n", headers: true)
    end

    test "skips rows before the records" do
      input = "Payment report\n\n" <> @ada <> "\n"

      assert {:ok, [%Payment{account: "12345678"}]} =
               Delimited.decode(Payment, input, skip_rows: 1)
    end
  end

  describe "writing" do
    test "places each value at its declared position" do
      assert encode(Payment, [ada()]) == @ada <> "\n"
    end

    test "fills undeclared positions with spaces" do
      assert encode(Payment, [ada()]) |> binary_part(9, 2) == "  "
    end

    test "pads each field on the side its alignment says" do
      row = %Payment{record_type: "6", account: "1", amount: 7, name: "N", active: false}

      assert encode(Payment, [row]) ==
               "6" <>
                 "1       " <> "  " <> "00000007" <> String.pad_trailing("N", 18) <> "0" <> "\n"
    end

    test "writes nil as the null string, padded" do
      assert encode(Payment, [%Payment{record_type: "6"}]) == @blank <> "\n"
    end

    test "refuses a value wider than its field" do
      row = %Payment{ada() | account: "123456789"}

      assert_raise Error, ~r/"123456789" needs 9 bytes and the field holds 8/, fn ->
        encode(Payment, [row])
      end
    end

    test "writes fixed-length blocks with no terminator" do
      row = %Block{code: "AB12", quantity: 42}

      assert encode(Block, [row, row]) == "AB1200000042AB1200000042"
    end

    test "pads a block out to its record length" do
      assert encode(Padded, [%Padded{code: "AB12"}]) == "AB12    "
    end

    test "writes a header line when told to, padded as text" do
      # No terminator: this schema frames records by length, not by line.
      assert encode(Block, [], headers: true) == "code" <> String.pad_trailing("quantity", 8)
    end

    test "leaves a field with no value blank rather than filling it with its pad" do
      written = encode(Payment, [%Payment{record_type: "6", amount: nil}])

      assert binary_part(written, 11, 8) == "        "
    end
  end

  describe "a round trip" do
    test "preserves every value" do
      rows = Delimited.decode!(Payment, Enum.join([@ada, @grace, @blank], "\n") <> "\n")

      assert Delimited.decode!(Payment, encode(Payment, rows)) == rows
    end

    test "rewrites the file it read, byte for byte" do
      file = Enum.join([@ada, @blank], "\n") <> "\n"

      assert encode(Payment, Delimited.decode!(Payment, file)) == file
    end

    test "preserves the difference between no value and zero" do
      rows = [
        %Payment{record_type: "6", amount: nil},
        %Payment{record_type: "6", amount: 0}
      ]

      assert [%Payment{amount: nil}, %Payment{amount: 0}] =
               Delimited.decode!(Payment, encode(Payment, rows))
    end

    test "does not preserve bytes that no field declares" do
      # Positions 10 and 11 are filler. Nothing reads them, so nothing can write
      # them back, and they are written blank.
      assert [written] =
               Payment |> Delimited.decode!(@grace <> "\n") |> then(&[encode(Payment, &1)])

      assert binary_part(@grace, 9, 2) == "XX"
      assert binary_part(written, 9, 2) == "  "
    end
  end

  test "a fixed schema reports its own layout" do
    assert Delimited.dialect(Payment).layout == :fixed
    assert Delimited.dialect(Payment).record_length == :line
    assert Delimited.dialect(Block).record_length == 12
  end

  defp ada do
    %Payment{
      record_type: "6",
      account: "12345678",
      amount: 1234,
      name: "Lovelace, Ada",
      active: true
    }
  end

  defp encode(schema, rows, opts \\ []) do
    schema |> Delimited.encode!(rows, opts) |> Enum.to_list() |> IO.iodata_to_binary()
  end
end
