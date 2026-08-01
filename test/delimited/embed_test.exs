defmodule Delimited.EmbedTest do
  use ExUnit.Case, async: true

  alias Delimited.Error
  alias Delimited.Field
  alias Delimited.Test.Address
  alias Delimited.Test.LineItem
  alias Delimited.Test.Order
  alias Delimited.Test.Party
  alias Delimited.Test.Transfer

  @headers "id,billing_street,billing_city,shipping_street,shipping_city," <>
             "item_1_sku,item_1_qty,item_2_sku,item_2_qty\n"

  describe "the columns an embed declares" do
    test "are the embedded schema's, prefixed" do
      assert Delimited.headers(Order) == [
               "id",
               "billing_street",
               "billing_city",
               "shipping_street",
               "shipping_city",
               "item_1_sku",
               "item_1_qty",
               "item_2_sku",
               "item_2_qty"
             ]
    end

    test "appear in the flat field list, so anything built on it keeps working" do
      assert length(Order.__delimited__(:fields)) == 9
      assert Enum.all?(Order.__delimited__(:fields), &match?(%Field{}, &1))
    end

    test "are the embedded schema's positions, shifted" do
      assert Enum.map(Transfer.__delimited__(:fields), &Field.declared_at/1) ==
               [1..1, 2..7, 8..15, 16..21, 22..29, 30..37]
    end
  end

  describe "reading" do
    test "builds a struct per embed" do
      assert {:ok, [order]} = decode("1,1 High St,Leeds,2 Low Rd,York,A-1,3,B-2,5")

      assert order == %Order{
               id: 1,
               billing: %Address{street: "1 High St", city: "Leeds"},
               shipping: %Address{street: "2 Low Rd", city: "York"},
               lines: [%LineItem{sku: "A-1", qty: 3}, %LineItem{sku: "B-2", qty: 5}]
             }
    end

    test "reads a group whose every column is empty as no group at all" do
      assert {:ok, [order]} = decode("1,1 High St,Leeds,,,A-1,3,B-2,5")

      assert order.shipping == nil
      assert order.billing == %Address{street: "1 High St", city: "Leeds"}
    end

    test "reads a group with one column filled as a group" do
      assert {:ok, [order]} = decode("1,,Leeds,,,,,,")

      assert order.billing == %Address{street: nil, city: "Leeds"}
    end

    test "reads each copy of a repeated group separately" do
      assert {:ok, [order]} = decode("1,,,,,A-1,3,,")

      assert order.lines == [%LineItem{sku: "A-1", qty: 3}, nil]
    end

    test "reads an entirely empty row as a row of nothing" do
      assert {:ok, [order]} = decode("1,,,,,,,,")

      assert order == %Order{id: 1, billing: nil, shipping: nil, lines: [nil, nil]}
    end

    test "names the column, not the embed, when a value cannot be read" do
      assert {:error, [%Error{reason: :cast_failed, value: "three"} = error]} =
               decode("1,,,,,A-1,three,,")

      assert Exception.message(error) =~ "column 7"
    end
  end

  describe "writing" do
    test "flattens the nesting back into columns" do
      order = %Order{
        id: 1,
        billing: %Address{street: "1 High St", city: "Leeds"},
        lines: [%LineItem{sku: "A-1", qty: 3}]
      }

      assert encode([order]) == @headers <> "1,1 High St,Leeds,,,A-1,3,,\n"
    end

    test "writes an absent group as empty columns" do
      assert encode([%Order{id: 1}]) == @headers <> "1,,,,,,,,\n"
    end

    test "pads a repeated group that the row does not fill" do
      order = %Order{id: 1, lines: [%LineItem{sku: "A-1", qty: 3}]}

      assert encode([order]) =~ ",A-1,3,,\n"
    end

    test "refuses more copies than the schema declares" do
      order = %Order{id: 1, lines: List.duplicate(%LineItem{sku: "A"}, 3)}

      assert_raise Error, ~r/at most 2 of them, which is how many the schema declares/, fn ->
        encode([order])
      end
    end

    test "refuses a repeated group that is not a list" do
      assert_raise Error, ~r/a list of at most 2 rows/, fn ->
        encode([%Order{id: 1, lines: %LineItem{}}])
      end
    end

    test "takes a plain map, nested the same way" do
      row = %{
        id: 1,
        billing: %{street: "1 High St", city: "Leeds"},
        shipping: nil,
        lines: [%{sku: "A-1", qty: 3}, nil]
      }

      assert encode([row]) == @headers <> "1,1 High St,Leeds,,,A-1,3,,\n"
    end

    test "reports a row that does not hold an embed at all" do
      assert_raise Error, ~r/field :shipping: the row holds no key/, fn ->
        encode([%{id: 1, billing: nil, lines: []}])
      end
    end
  end

  describe "a round trip" do
    test "preserves the nesting" do
      file = @headers <> "1,1 High St,Leeds,,,A-1,3,B-2,5\n2,,,,,,,,\n"

      assert encode(Delimited.decode!(Order, file)) == file
    end
  end

  describe "the fixed layout" do
    #      1|2-----7------14|16----21------29|30
    @line "6" <> "1234569876543 " <> "6543211234567 " <> "00001234"

    test "counts an embedded schema's positions from where the embed starts" do
      assert {:ok, [transfer]} = Delimited.decode(Transfer, @line <> "\n")

      assert transfer == %Transfer{
               record_type: "6",
               payer: %Party{sort_code: "123456", account: "9876543"},
               payee: %Party{sort_code: "654321", account: "1234567"},
               amount: 1234
             }
    end

    test "writes the blocks back where it found them" do
      rows = Delimited.decode!(Transfer, @line <> "\n")

      assert encode(Transfer, rows) == @line <> "\n"
    end

    test "repeats a block by its own width unless told otherwise" do
      defmodule Batch do
        @moduledoc false
        use Delimited.Schema

        delimited_schema :fixed do
          field :kind, :string, at: 1..1
          embeds_many :parties, Delimited.Test.Party, count: 3, at: 2
        end
      end

      assert Enum.map(Batch.__delimited__(:fields), &Field.declared_at/1) ==
               [1..1, 2..7, 8..15, 16..21, 22..29, 30..35, 36..43]
    end

    test "leaves a declared gap between copies" do
      defmodule Spaced do
        @moduledoc false
        use Delimited.Schema

        delimited_schema :fixed do
          embeds_many :parties, Delimited.Test.Party, count: 2, at: 1, stride: 20
        end
      end

      assert Enum.map(Spaced.__delimited__(:fields), &Field.declared_at/1) ==
               [1..6, 7..14, 21..26, 27..34]
    end
  end

  describe "nesting" do
    test "an embed may hold an embed" do
      defmodule Contact do
        @moduledoc false
        use Delimited.Schema

        delimited_schema do
          field :name, :string
          embeds_one :address, Delimited.Test.Address, prefix: "addr_"
        end
      end

      defmodule Company do
        @moduledoc false
        use Delimited.Schema

        delimited_schema do
          embeds_one :owner, Contact, prefix: "owner_"
        end
      end

      assert Delimited.headers(Company) == ["owner_name", "owner_addr_street", "owner_addr_city"]

      assert {:ok, [company]} =
               Delimited.decode(
                 Company,
                 "owner_name,owner_addr_street,owner_addr_city\nAda,1 High St,Leeds\n"
               )

      assert company.owner.name == "Ada"
      assert company.owner.address == %Address{street: "1 High St", city: "Leeds"}
    end
  end

  describe "required" do
    test "an absent group is an error when reading or writing" do
      defmodule Invoiced do
        @moduledoc false
        use Delimited.Schema

        delimited_schema do
          field :id, :integer
          embeds_one :billing, Delimited.Test.Address, prefix: "billing_", required: true
        end
      end

      assert {:error, [%Error{reason: :required_field_missing, field: :billing, line: 2}]} =
               Delimited.decode(Invoiced, "id,billing_street,billing_city\n1,,\n")

      assert {:ok, [_present]} =
               Delimited.decode(Invoiced, "id,billing_street,billing_city\n1,1 High St,\n")

      error = assert_raise Error, fn -> encode(Invoiced, [%{id: 1, billing: nil}]) end

      assert error.reason == :required_field_missing
      assert error.field == :billing
      assert error.line == 2
    end
  end

  describe "declaration errors" do
    test "refuses a module that is not a schema" do
      assert_raise ArgumentError, ~r/is not a schema/, fn ->
        defmodule NotASchema do
          use Delimited.Schema

          delimited_schema do
            embeds_one :thing, URI
          end
        end
      end
    end

    test "refuses an embedded schema of the other layout" do
      assert_raise ArgumentError, ~r/is declared :delimited and is embedded/, fn ->
        defmodule MixedLayout do
          use Delimited.Schema

          delimited_schema :fixed do
            field :a, :string, at: 1..2
            embeds_one :b, Delimited.Test.Address, at: 3
          end
        end
      end
    end

    test "refuses a repeated group with no count" do
      assert_raise ArgumentError, ~r/needs a positive :count/, fn ->
        defmodule Countless do
          use Delimited.Schema

          delimited_schema do
            embeds_many :lines, Delimited.Test.LineItem, prefix: "item_{n}_"
          end
        end
      end
    end

    test "refuses a repeated group whose prefix does not number its copies" do
      assert_raise ArgumentError, ~r/does not hold \{n\}/, fn ->
        defmodule Unnumbered do
          use Delimited.Schema

          delimited_schema do
            embeds_many :lines, Delimited.Test.LineItem, count: 2, prefix: "item_"
          end
        end
      end
    end

    test "refuses an unknown option" do
      assert_raise ArgumentError, ~r/unknown option :prefx/, fn ->
        defmodule Misspelt do
          use Delimited.Schema

          delimited_schema do
            embeds_one :billing, Delimited.Test.Address, prefx: "billing_"
          end
        end
      end
    end

    test "refuses two embeds that would claim the same columns" do
      assert_raise ArgumentError, ~r/declares the header "(street|city)" more than once/, fn ->
        defmodule Colliding do
          use Delimited.Schema

          delimited_schema do
            embeds_one :billing, Delimited.Test.Address
            embeds_one :shipping, Delimited.Test.Address
          end
        end
      end
    end

    test "refuses an embed whose name is already a field's" do
      assert_raise ArgumentError, ~r/declares the name :billing more than once/, fn ->
        defmodule Shadowed do
          use Delimited.Schema

          delimited_schema do
            field :billing, :string
            embeds_one :billing, Delimited.Test.Address, prefix: "b_"
          end
        end
      end
    end

    test "allows two embeds of one schema to hold the same field names" do
      assert Enum.map(Order.__delimited__(:fields), & &1.name) ==
               [:id, :street, :city, :street, :city, :sku, :qty, :sku, :qty]
    end
  end

  defp decode(cells), do: Delimited.decode(Order, @headers <> cells <> "\n")

  defp encode(rows), do: encode(Order, rows)

  defp encode(schema, rows) do
    schema |> Delimited.encode!(rows) |> Enum.to_list() |> IO.iodata_to_binary()
  end
end
