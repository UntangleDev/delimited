defmodule Delimited.ParserTest do
  use ExUnit.Case, async: true

  alias Delimited.Dialect
  alias Delimited.Error
  alias Delimited.Parser

  describe "fields" do
    test "reads unquoted cells" do
      assert rows("a,b,c\n") == [["a", "b", "c"]]
    end

    test "reads empty cells" do
      assert rows(",,\n") == [["", "", ""]]
    end

    test "reads a final row with no line break" do
      assert rows("a,b") == [["a", "b"]]
    end

    test "reads a final cell with no value" do
      assert rows("a,") == [["a", ""]]
    end

    test "keeps whitespace" do
      assert rows(" a , b \n") == [[" a ", " b "]]
    end

    test "keeps non-ASCII text" do
      assert rows("Ada,café,日本\n") == [["Ada", "café", "日本"]]
    end
  end

  describe "quoting" do
    test "reads a quoted cell" do
      assert rows(~s("a","b"\n)) == [["a", "b"]]
    end

    test "reads a delimiter inside a quoted cell" do
      assert rows(~s("a,b",c\n)) == [["a,b", "c"]]
    end

    test "reads a line break inside a quoted cell" do
      assert rows(~s("a\nb",c\n)) == [["a\nb", "c"]]
    end

    test "reads a doubled quote as one quote" do
      assert rows(~s("a""b"\n)) == [[~s(a"b)]]
    end

    test "reads a cell that is only a doubled quote" do
      assert rows(~s(""""\n)) == [[~s(")]]
    end

    test "reads an empty quoted cell" do
      assert rows(~s("",a\n)) == [["", "a"]]
    end

    test "reads a quote inside an unquoted cell as data" do
      assert rows(~s(a"b,c\n)) == [[~s(a"b), "c"]]
    end

    test "refuses a character after a closing quote" do
      assert {:error, %Error{reason: :unescaped_quote, line: 1, column: 1}} =
               parse_error(~s("a"b\n))
    end

    test "refuses a quote left open" do
      assert {:error, %Error{reason: :unterminated_quote, line: 1}} = parse_error(~s("a,b\n))
    end

    test "reports the line a quote was left open on" do
      assert {:error, %Error{reason: :unterminated_quote, line: 2}} = parse_error(~s(a\n"b\n))
    end
  end

  describe "line breaks" do
    test "reads CRLF as a row terminator" do
      assert rows("a,b\r\nc,d\r\n") == [["a", "b"], ["c", "d"]]
    end

    test "reads a lone carriage return as data" do
      assert rows("a\rb,c\n") == [["a\rb", "c"]]
    end

    test "reads a trailing carriage return as data" do
      assert rows("a,b\r") == [["a", "b\r"]]
    end

    test "keeps CRLF inside a quoted cell" do
      assert rows(~s("a\r\nb"\n)) == [["a\r\nb"]]
    end

    test "does not read a row after the final line break" do
      assert rows("a\n") == [["a"]]
      assert rows("a\r\n") == [["a"]]
    end

    test "skips blank lines" do
      assert rows("a\n\n\nb\n") == [["a"], ["b"]]
    end

    test "keeps blank lines when told to" do
      assert rows("a\n\nb\n", skip_blank_lines: false) == [["a"], [""], ["b"]]
    end

    test "reads a line of only whitespace as a cell" do
      assert rows("a\n \nb\n") == [["a"], [" "], ["b"]]
    end
  end

  describe "comments" do
    test "discards a commented line" do
      assert rows("# a note\na,b\n", comment: "#") == [["a", "b"]]
    end

    test "discards a commented line holding anything at all" do
      # The reason comments are handled while framing rather than after: this
      # line would otherwise open a quoted field and swallow the rest of the
      # file.
      assert rows(~s(# don't, "even, try\na,b\n), comment: "#") == [["a", "b"]]
    end

    test "discards a commented last line with no terminator" do
      assert rows("a,b\n# trailing", comment: "#") == [["a", "b"]]
    end

    test "keeps the comment character anywhere but the start of a line" do
      assert rows("a,#b\n", comment: "#") == [["a", "#b"]]
      assert rows(~s("#a",b\n), comment: "#") == [["#a", "b"]]
    end

    test "keeps a commented line when no comment character is declared" do
      assert rows("# a note\na,b\n") == [["# a note"], ["a", "b"]]
    end

    test "counts a commented line when numbering rows" do
      assert lines("# one\na\n# three\nb\n", comment: "#") == [2, 4]
    end

    test "frames the same rows however a comment is sliced" do
      input = "# a note\na,b\n#\nc,d\n"
      expected = rows(input, comment: "#")

      for size <- 1..byte_size(input) do
        assert rows_in_slices(slice(input, size), comment: "#") == expected,
               "differs when sliced every #{size} bytes"
      end
    end
  end

  describe "line numbers" do
    test "counts rows from one" do
      assert lines("a\nb\nc\n") == [1, 2, 3]
    end

    test "counts line breaks inside quoted cells" do
      assert lines(~s(a\n"b\nc"\nd\n)) == [1, 2, 4]
    end

    test "counts blank lines that it skips" do
      assert lines("a\n\n\nb\n") == [1, 4]
    end
  end

  describe "byte order marks" do
    test "strips a leading byte order mark" do
      assert rows(<<0xEF, 0xBB, 0xBF>> <> "a,b\n") == [["a", "b"]]
    end

    test "keeps a byte order mark that is not leading" do
      assert rows("a\n" <> <<0xEF, 0xBB, 0xBF>> <> "b\n") == [
               ["a"],
               [<<0xEF, 0xBB, 0xBF>> <> "b"]
             ]
    end

    test "strips a byte order mark split across slices" do
      assert rows_in_slices([<<0xEF>>, <<0xBB, 0xBF>>, "a,b\n"]) == [["a", "b"]]
    end
  end

  describe "dialects" do
    test "reads another delimiter" do
      assert rows("a\tb\n", delimiter: "\t") == [["a", "b"]]
    end

    test "reads another quote character" do
      assert rows("'a,b',c\n", quote_char: "'") == [["a,b", "c"]]
    end

    test "treats the standard quote as data under another quote character" do
      assert rows(~s("a",b\n), quote_char: "'") == [[~s("a"), "b"]]
    end
  end

  describe "slicing" do
    test "reads the same rows however the input is sliced" do
      input = ~s(id,name\r\n1,"Lovelace, Ada"\r\n2,"say ""hi""\nagain"\r\n3,\r\n)
      expected = rows(input)

      for size <- 1..byte_size(input) do
        assert rows_in_slices(slice(input, size)) == expected,
               "differs when sliced every #{size} bytes"
      end
    end

    test "reports the same failure however the input is sliced" do
      input = ~s(a,b\n"c"d\ne,f\n)
      expected = results(input)

      assert [{:ok, _row}, {:error, %Error{reason: :unescaped_quote}}] = expected

      for size <- 1..byte_size(input) do
        assert parse(slice(input, size), []) == expected,
               "differs when sliced every #{size} bytes"
      end
    end

    test "reads an empty slice as nothing" do
      assert rows_in_slices(["a,b", "", "\n"]) == [["a", "b"]]
    end

    test "reads no rows from no input" do
      assert rows("") == []
      assert rows_in_slices([]) == []
    end
  end

  describe "errors" do
    test "stops at the first error" do
      results = results(~s(a\n"b"c\nd\n))

      assert [{:ok, {1, ["a"]}}, {:error, %Error{reason: :unescaped_quote}}] = results
    end

    test "refuses a source that does not yield binaries" do
      assert_raise ArgumentError, ~r/expected the source to yield binaries/, fn ->
        [:not_a_binary] |> Parser.stream(Dialect.new!()) |> Enum.to_list()
      end
    end
  end

  defp parse(slices, opts), do: slices |> Parser.stream(Dialect.new!(opts)) |> Enum.to_list()

  defp results(input, opts \\ []), do: parse([input], opts)

  defp rows_in_slices(slices, opts \\ []) do
    slices |> parse(opts) |> Enum.map(fn {:ok, {_line, cells}} -> cells end)
  end

  defp rows(input, opts \\ []), do: rows_in_slices([input], opts)

  defp lines(input, opts \\ []) do
    [input] |> parse(opts) |> Enum.map(fn {:ok, {line, _cells}} -> line end)
  end

  defp parse_error(input) do
    [input] |> parse([]) |> Enum.find(&match?({:error, _error}, &1))
  end

  defp slice(input, size) do
    input
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end
