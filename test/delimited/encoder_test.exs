defmodule Delimited.EncoderTest do
  use ExUnit.Case, async: true

  alias Delimited.Dialect
  alias Delimited.Encoder

  describe "quoting" do
    test "leaves a plain cell unquoted" do
      assert encode(["a", "b"]) == "a,b\n"
    end

    test "quotes a cell holding the delimiter" do
      assert encode(["a,b", "c"]) == ~s("a,b",c\n)
    end

    test "quotes a cell holding a quote, and doubles the quote" do
      assert encode([~s(a"b)]) == ~s("a""b"\n)
    end

    test "quotes a cell holding a line break" do
      assert encode(["a\nb"]) == ~s("a\nb"\n)
      assert encode(["a\rb"]) == ~s("a\rb"\n)
    end

    test "quotes every cell when told to" do
      assert encode(["a", ""], quoting: :always) == ~s("a",""\n)
    end

    test "quotes a lone empty cell so that the row survives" do
      assert encode([""]) == ~s(""\n)
      assert encode(["", ""]) == ",\n"
    end

    test "quotes against the declared delimiter, not the comma" do
      assert encode(["a,b"], delimiter: "\t") == "a,b\n"
      assert encode(["a\tb"], delimiter: "\t") == ~s("a\tb"\n)
    end
  end

  describe "line breaks" do
    test "ends a row with a line feed" do
      assert encode(["a"]) == "a\n"
    end

    test "ends a row with CRLF when told to" do
      assert encode(["a"], newline: "\r\n") == "a\r\n"
    end
  end

  describe "formula escaping" do
    test "is off by default" do
      assert encode(["=1+1"]) == "=1+1\n"
    end

    test "prefixes a cell a spreadsheet would evaluate" do
      for text <- ["=1+1", "+SUM(A1)", "@SUM(A1)", "-cmd", "\tx"] do
        assert encode([text], escape_formulas: true) == quoted("'" <> text)
      end
    end

    test "leaves a number alone" do
      for text <- ["-1", "-1.5", "+2", "-1.5e3", "-.5"] do
        assert encode([text], escape_formulas: true) == text <> "\n"
      end
    end

    test "leaves a cell that starts with something else alone" do
      assert encode(["SUM(A1)"], escape_formulas: true) == "SUM(A1)\n"
    end
  end

  defp encode(cells, opts \\ []) do
    cells |> Encoder.row(Dialect.new!(opts)) |> IO.iodata_to_binary()
  end

  defp quoted(text) do
    if String.contains?(text, ["\r", "\n", ",", "\""]) do
      ~s("#{text}"\n)
    else
      text <> "\n"
    end
  end
end
