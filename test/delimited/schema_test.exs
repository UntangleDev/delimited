defmodule Delimited.SchemaTest do
  use ExUnit.Case, async: true

  alias Delimited.Field
  alias Delimited.Test.Employee
  alias Delimited.Test.Product

  doctest Delimited.Schema

  describe "the generated struct" do
    test "holds one key per field, defaulting to the field's default" do
      assert %Employee{
               id: nil,
               name: nil,
               department: nil,
               hired_on: nil,
               salary: nil,
               active: true
             } = %Employee{}
    end
  end

  describe "__delimited__/1" do
    test "returns the fields in declaration order" do
      assert Enum.map(Employee.__delimited__(:fields), & &1.name) ==
               [:id, :name, :department, :hired_on, :salary, :active]
    end

    test "returns each field's declaration" do
      [id | _rest] = Employee.__delimited__(:fields)

      assert %Field{name: :id, type: :integer, header: "Employee ID", required: false} = id
    end

    test "defaults a header to the field name" do
      assert Delimited.headers(Product) == ["sku", "price"]
    end

    test "returns the declared dialect" do
      assert Delimited.dialect(Employee).delimiter == ?,
      assert Delimited.dialect(Product).delimiter == ?\t
      assert Delimited.dialect(Product).headers == false
    end
  end

  describe "declaration errors" do
    test "refuses a schema with no fields" do
      assert_raise ArgumentError, ~r/declares no fields/, fn ->
        defmodule Empty do
          use Delimited.Schema

          delimited_schema do
          end
        end
      end
    end

    test "refuses two fields with the same name" do
      assert_raise ArgumentError, ~r/declares the name :a more than once/, fn ->
        defmodule DuplicateName do
          use Delimited.Schema

          delimited_schema do
            field :a, :string
            field :a, :integer
          end
        end
      end
    end

    test "refuses two fields reading the same column" do
      assert_raise ArgumentError, ~r/declares the header "same" more than once/, fn ->
        defmodule DuplicateHeader do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, header: "same"
            field :b, :string, header: "same"
          end
        end
      end
    end

    test "refuses an unknown type" do
      assert_raise ArgumentError, ~r/unknown type :interger/, fn ->
        defmodule UnknownType do
          use Delimited.Schema

          delimited_schema do
            field :a, :interger
          end
        end
      end
    end

    test "refuses an unknown option on a built-in type" do
      assert_raise ArgumentError, ~r/unknown option :heder on field :a/, fn ->
        defmodule UnknownOption do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, heder: "A"
          end
        end
      end
    end

    test "refuses a required field that also declares a default" do
      assert_raise ArgumentError, ~r/is required and also declares a default/, fn ->
        defmodule RequiredWithDefault do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, required: true, default: "x"
          end
        end
      end
    end

    test "refuses an unknown dialect option" do
      assert_raise ArgumentError, ~r/unknown dialect option :delimeter/, fn ->
        defmodule UnknownDialectOption do
          use Delimited.Schema

          delimited_schema delimeter: ";" do
            field :a, :string
          end
        end
      end
    end
  end

  describe "fixed-width declaration errors" do
    test "refuses a fixed field with no position" do
      assert_raise ArgumentError, ~r/declares no position/, fn ->
        defmodule NoPosition do
          use Delimited.Schema

          delimited_schema :fixed do
            field :a, :string, at: 1..2
            field :b, :string
          end
        end
      end
    end

    test "refuses two fields covering the same bytes" do
      assert_raise ArgumentError, ~r/:a at 1..8 and :b at 5..12.*same bytes/s, fn ->
        defmodule Overlapping do
          use Delimited.Schema

          delimited_schema :fixed do
            field :a, :string, at: 1..8
            field :b, :string, at: 5..12
          end
        end
      end
    end

    test "allows a gap between fields, which is filler" do
      defmodule WithFiller do
        use Delimited.Schema

        delimited_schema :fixed do
          field :a, :string, at: 1..2
          field :b, :string, at: 9..10
        end
      end

      assert [%Field{at: {0, 2}}, %Field{at: {8, 2}}] = WithFiller.__delimited__(:fields)
    end

    test "refuses a field that ends beyond the declared record length" do
      assert_raise ArgumentError, ~r/ends at position 20, beyond the declared/, fn ->
        defmodule TooLong do
          use Delimited.Schema

          delimited_schema :fixed, record_length: 10 do
            field :a, :string, at: 1..20
          end
        end
      end
    end

    test "refuses a position on a delimited schema, which could not honour it" do
      assert_raise ArgumentError, ~r/declares :at, which only the fixed-width layout/, fn ->
        defmodule PositionedDelimited do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, at: 1..8
          end
        end
      end
    end

    test "refuses an alignment on a delimited schema" do
      assert_raise ArgumentError, ~r/declares :align, which only the fixed-width layout/, fn ->
        defmodule AlignedDelimited do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, align: :right
          end
        end
      end
    end

    test "refuses a pad on a delimited schema" do
      assert_raise ArgumentError, ~r/declares :pad, which only the fixed-width layout/, fn ->
        defmodule PaddedDelimited do
          use Delimited.Schema

          delimited_schema do
            field :a, :string, pad: ?0
          end
        end
      end
    end
  end

  describe "custom type options" do
    test "reach the type" do
      defmodule Priced do
        use Delimited.Schema

        delimited_schema do
          field :price, Delimited.Test.Money, symbol: "$"
        end
      end

      assert [%Field{opts: [symbol: "$"]}] = Priced.__delimited__(:fields)
      assert {:ok, [%{price: 150}]} = Delimited.decode(Priced, "price\n$1.50\n")
    end
  end

  describe "a module that is not a schema" do
    test "is refused with the reason" do
      assert_raise ArgumentError, ~r/expected a module that calls `use Delimited.Schema`/, fn ->
        Delimited.decode(URI, "a\n1\n")
      end
    end
  end
end
