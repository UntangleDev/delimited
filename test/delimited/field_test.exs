defmodule Delimited.FieldTest do
  use ExUnit.Case, async: true

  alias Delimited.Field

  describe "new!/3" do
    test "defaults the header to the field name" do
      assert %Field{header: "hired_on", type: :date, required: false, opts: []} =
               Field.new!(:hired_on, :date, [])
    end

    test "keeps the declared options" do
      field = Field.new!(:name, :string, header: "Name", required: true, trim: true, null: ["-"])

      assert %Field{header: "Name", required: true, trim: true, null: ["-"]} = field
    end

    test "leaves trim and null unset so that the dialect decides" do
      assert %Field{trim: nil, null: nil} = Field.new!(:name, :string, [])
    end

    test "refuses a header that is not a string" do
      assert_raise ArgumentError, ~r/must be a non-empty string/, fn ->
        Field.new!(:name, :string, header: :name)
      end

      assert_raise ArgumentError, ~r/must be a non-empty string/, fn ->
        Field.new!(:name, :string, header: "")
      end
    end

    test "refuses a null option that is not a list of strings" do
      assert_raise ArgumentError, ~r/must be a list of strings/, fn ->
        Field.new!(:name, :string, null: "NULL")
      end

      assert_raise ArgumentError, ~r/must be strings/, fn ->
        Field.new!(:name, :string, null: [nil])
      end
    end

    test "refuses required or trim given as anything but a boolean" do
      assert_raise ArgumentError, ~r/must be true or false/, fn ->
        Field.new!(:name, :string, required: :yes)
      end

      assert_raise ArgumentError, ~r/must be true or false/, fn ->
        Field.new!(:name, :string, trim: 1)
      end
    end

    test "refuses a name that is not an atom" do
      assert_raise ArgumentError, ~r/an atom name and a keyword list/, fn ->
        Field.new!("name", :string, [])
      end
    end

    test "names every unknown option it refuses" do
      error =
        assert_raise ArgumentError, fn ->
          Field.new!(:name, :string, heder: "Name", requried: true)
        end

      message = Exception.message(error)

      assert message =~ "unknown options :heder, :requried on field :name"
      assert message =~ "Only a custom type module receives further options"
    end

    test "passes unknown options to a custom type" do
      assert %Field{opts: [symbol: "$"]} =
               Field.new!(:price, Delimited.Test.Money, symbol: "$")
    end
  end
end
