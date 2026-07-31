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
      assert_raise ArgumentError, ~r/unknown format :xlsx/, fn -> Dialect.new!(:xlsx) end
    end

    test "names the delimiter of every format it knows" do
      assert Dialect.new!(:csv).delimiter == ?,
      assert Dialect.new!(:tsv).delimiter == ?\t
      assert Dialect.new!(:psv).delimiter == ?|
      assert Dialect.new!(:ssv).delimiter == ?\s
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

  describe "comments" do
    test "no line is a comment unless one is declared" do
      assert Dialect.new!().comment == nil
    end

    test "takes a comment byte as a string or a codepoint" do
      assert Dialect.new!(comment: "#").comment == ?#
      assert Dialect.new!(comment: ?#).comment == ?#
    end

    test "refuses a comment of more than one byte" do
      assert_raise ArgumentError, ~r/single ASCII character/, fn ->
        Dialect.new!(comment: "//")
      end
    end
  end

  describe "layouts" do
    test "defaults to the delimited layout framed by lines" do
      assert %Dialect{layout: :delimited, record_length: :line} = Dialect.new!()
    end

    test "the fixed format selects the layout and turns headers off" do
      assert %Dialect{layout: :fixed, headers: false} = Dialect.new!(:fixed)
    end

    test "takes a record length for a file with no terminators" do
      assert Dialect.new!(:fixed, record_length: 100).record_length == 100
    end

    test "refuses a record length that is neither :line nor a positive integer" do
      for bad <- [0, -1, "100", :fixed] do
        assert_raise ArgumentError, ~r/must be :line, or a positive integer/, fn ->
          Dialect.new!(record_length: bad)
        end
      end
    end

    test "refuses an unknown layout" do
      assert_raise ArgumentError, ~r/must be one of \[:delimited, :fixed\]/, fn ->
        Dialect.new!(layout: :columnar)
      end
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

    test "a format applies only the options it names" do
      # :tsv says nothing about null strings, so it leaves them alone.
      dialect = Dialect.new!(null: ["N/A"]) |> Dialect.merge!(:tsv)

      assert dialect.null == ["N/A"]
      assert dialect.delimiter == ?\t
    end

    test "returns a fixed dialect to the delimited layout" do
      assert Dialect.new!(:fixed) |> Dialect.merge!(:csv) |> Map.get(:layout) == :delimited
    end
  end
end
