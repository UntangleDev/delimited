defmodule Delimited.TypeTest do
  use ExUnit.Case, async: true

  alias Delimited.Type

  describe "cast/3" do
    test "reads text" do
      assert Type.cast(:string, "  a  ", []) == {:ok, "  a  "}
    end

    test "reads whole numbers" do
      assert Type.cast(:integer, "42", []) == {:ok, 42}
      assert Type.cast(:integer, "-42", []) == {:ok, -42}
      assert Type.cast(:integer, "+42", []) == {:ok, 42}
    end

    test "refuses a partly read number" do
      assert {:error, _expected} = Type.cast(:integer, "42abc", [])
      assert {:error, _expected} = Type.cast(:integer, "4.2", [])
      assert {:error, _expected} = Type.cast(:integer, " 42", [])
      assert {:error, _expected} = Type.cast(:float, "1,5", [])
    end

    test "reads numbers" do
      assert Type.cast(:float, "1.5", []) == {:ok, 1.5}
      assert Type.cast(:float, "-1.5e3", []) == {:ok, -1500.0}
      assert Type.cast(:float, "2", []) == {:ok, 2.0}
    end

    test "reads booleans in any case" do
      for text <- ~w(true TRUE t yes Y 1),
          do: assert(Type.cast(:boolean, text, []) == {:ok, true})

      for text <- ~w(false F no N 0), do: assert(Type.cast(:boolean, text, []) == {:ok, false})
    end

    test "refuses other booleans" do
      assert {:error, _expected} = Type.cast(:boolean, "maybe", [])
      assert {:error, _expected} = Type.cast(:boolean, "2", [])
    end

    test "reads dates and times" do
      assert Type.cast(:date, "2024-02-29", []) == {:ok, ~D[2024-02-29]}
      assert Type.cast(:time, "09:30:00", []) == {:ok, ~T[09:30:00]}

      assert Type.cast(:naive_datetime, "2024-02-29 09:30:00", []) ==
               {:ok, ~N[2024-02-29 09:30:00]}
    end

    test "refuses a date that does not exist" do
      assert {:error, _expected} = Type.cast(:date, "2023-02-29", [])
      assert {:error, _expected} = Type.cast(:date, "2024-2-9", [])
      assert {:error, _expected} = Type.cast(:date, "29/02/2024", [])
    end

    test "converts a date and time with an offset to UTC" do
      assert Type.cast(:utc_datetime, "2024-03-01T12:00:00+02:00", []) ==
               {:ok, ~U[2024-03-01 10:00:00Z]}
    end

    test "reads finite decimals" do
      assert Type.cast(:decimal, "1200.50", []) == {:ok, Decimal.new("1200.50")}
      assert Type.cast(:decimal, "-0.01", []) == {:ok, Decimal.new("-0.01")}
    end

    test "refuses decimals that are not measurements" do
      assert {:error, _expected} = Type.cast(:decimal, "NaN", [])
      assert {:error, _expected} = Type.cast(:decimal, "Infinity", [])
      assert {:error, _expected} = Type.cast(:decimal, "1.2.3", [])
    end

    test "reads an enumeration by its own text" do
      assert Type.cast({:enum, [draft: "draft"]}, "draft", []) == {:ok, :draft}
    end

    test "reads an enumeration by its declared text" do
      values = [draft: "D", published: "P"]
      assert Type.cast({:enum, values}, "P", []) == {:ok, :published}
      assert {:error, _expected} = Type.cast({:enum, values}, "published", [])
    end
  end

  describe "dump/3" do
    test "writes each built-in type" do
      assert Type.dump(:string, "a", []) == {:ok, "a"}
      assert Type.dump(:integer, 42, []) == {:ok, "42"}
      assert Type.dump(:float, 1.5, []) == {:ok, "1.5"}
      assert Type.dump(:boolean, true, []) == {:ok, "true"}
      assert Type.dump(:date, ~D[2024-02-29], []) == {:ok, "2024-02-29"}
      assert Type.dump(:time, ~T[09:30:00], []) == {:ok, "09:30:00"}
      assert Type.dump(:decimal, Decimal.new("1200.50"), []) == {:ok, "1200.50"}
    end

    test "writes a whole number in a float field" do
      assert Type.dump(:float, 2, []) == {:ok, "2"}
    end

    test "writes a decimal without an exponent" do
      assert Type.dump(:decimal, Decimal.new("1E3"), []) == {:ok, "1000"}
    end

    test "refuses a value of the wrong type" do
      assert {:error, _expected} = Type.dump(:integer, "42", [])
      assert {:error, _expected} = Type.dump(:date, "2024-02-29", [])
      assert {:error, _expected} = Type.dump(:string, 42, [])
    end

    test "refuses a term the enumeration does not declare" do
      assert {:error, _expected} = Type.dump({:enum, [draft: "D"]}, :published, [])
    end
  end

  describe "validate!/1" do
    test "returns a built-in type" do
      assert Type.validate!(:integer) == :integer
    end

    test "normalises an enumeration of atoms" do
      assert Type.validate!({:enum, [:draft, :published]}) ==
               {:enum, [draft: "draft", published: "published"]}
    end

    test "keeps a declared mapping" do
      assert Type.validate!({:enum, [draft: "D"]}) == {:enum, [draft: "D"]}
    end

    test "refuses an unknown type" do
      assert_raise ArgumentError, ~r/unknown type :integr/, fn -> Type.validate!(:integr) end
    end

    test "refuses an enumeration value that is neither an atom nor a mapping" do
      assert_raise ArgumentError, ~r/invalid enumeration value/, fn ->
        Type.validate!({:enum, ["draft"]})
      end
    end

    test "accepts a module without loading it" do
      assert Type.validate!(NoSuchModule) == NoSuchModule
    end
  end

  describe "a custom type" do
    alias Delimited.Test.Money

    test "reads and writes through the behaviour" do
      assert Money.cast("£12.34", []) == {:ok, 1234}
      assert {:ok, dumped} = Money.dump(1234, [])
      assert IO.iodata_to_binary(dumped) == "£12.34"
    end

    test "receives the options the field declares" do
      assert Money.cast("$1.00", symbol: "$") == {:ok, 100}
      assert {:error, "an amount in $"} = Money.cast("£1.00", symbol: "$")
    end
  end
end
