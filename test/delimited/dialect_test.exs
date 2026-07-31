defmodule Delimited.DialectTest do
  use ExUnit.Case, async: true

  alias Delimited.Dialect

  describe "new!/2" do
    test "defaults to comma-separated values" do
      assert %Dialect{delimiter: ?,, quote_char: ?", headers: true} = Dialect.new!()
    end

    test "takes a format name" do
      assert Dialect.new!(:tsv).delimiter == ?\t
    end

    test "takes options" do
      assert Dialect.new!(delimiter: ";").delimiter == ?;
    end

    test "takes a format name and options" do
      dialect = Dialect.new!(:tsv, headers: false)

      assert dialect.delimiter == ?\t
      assert dialect.headers == false
    end

    test "takes a delimiter as a string or a codepoint" do
      assert Dialect.new!(delimiter: "|").delimiter == ?|
      assert Dialect.new!(delimiter: ?|).delimiter == ?|
    end

    test "refuses an unknown format" do
      assert_raise ArgumentError, ~r/unknown format :psv/, fn -> Dialect.new!(:psv) end
    end

    test "refuses an unknown option" do
      assert_raise ArgumentError, ~r/unknown dialect option :seperator/, fn ->
        Dialect.new!(seperator: ";")
      end
    end

    test "refuses a delimiter of more than one byte" do
      assert_raise ArgumentError, ~r/single ASCII character/, fn ->
        Dialect.new!(delimiter: "||")
      end

      assert_raise ArgumentError, ~r/single ASCII character/, fn ->
        Dialect.new!(delimiter: "§")
      end
    end

    test "refuses a delimiter that is a line break" do
      assert_raise ArgumentError, ~r/other than a line break/, fn ->
        Dialect.new!(delimiter: "\n")
      end
    end

    test "refuses a delimiter equal to the quote character" do
      assert_raise ArgumentError, ~r/could not then be told from its own quoting/, fn ->
        Dialect.new!(delimiter: "\"")
      end
    end

    test "refuses an option of the wrong type" do
      assert_raise ArgumentError, ~r/must be true or false/, fn -> Dialect.new!(headers: :yes) end
      assert_raise ArgumentError, ~r/must be one of/, fn -> Dialect.new!(newline: "\r") end
      assert_raise ArgumentError, ~r/list of strings/, fn -> Dialect.new!(null: "NULL") end
      assert_raise ArgumentError, ~r/non-negative integer/, fn -> Dialect.new!(skip_rows: -1) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> Dialect.new!(chunk_size: 0) end
    end
  end

  describe "merge!/2" do
    test "applies options over a dialect" do
      assert Dialect.new!(:tsv) |> Dialect.merge!(headers: false) |> Map.get(:headers) == false
    end

    test "applies a format over a dialect" do
      assert Dialect.new!(headers: false) |> Dialect.merge!(:tsv) |> Map.get(:delimiter) == ?\t
    end

    test "keeps the rest of the dialect when applying a format" do
      assert Dialect.new!(headers: false) |> Dialect.merge!(:tsv) |> Map.get(:headers) == false
    end
  end
end
