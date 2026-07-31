defmodule Delimited.FixedTest do
  use ExUnit.Case, async: true

  alias Delimited.Dialect
  alias Delimited.Error
  alias Delimited.Fixed

  describe "line framing" do
    test "frames a record per line" do
      assert records("ab\ncd\n") == ["ab", "cd"]
    end

    test "frames a final record with no terminator" do
      assert records("ab\ncd") == ["ab", "cd"]
    end

    test "frames CRLF" do
      assert records("ab\r\ncd\r\n") == ["ab", "cd"]
    end

    test "keeps a carriage return that is not a terminator" do
      assert records("a\rb\n") == ["a\rb"]
    end

    test "does not frame a record after the final terminator" do
      assert records("ab\n") == ["ab"]
    end

    test "skips an empty line" do
      assert records("ab\n\n\ncd\n") == ["ab", "cd"]
    end

    test "keeps an empty line when told to" do
      assert records("ab\n\ncd\n", skip_blank_lines: false) == ["ab", "", "cd"]
    end

    test "reads a line of spaces as a record, not as blank" do
      assert records("  \n") == ["  "]
    end

    test "frames records of differing lengths" do
      assert records("a\nbbb\ncc\n") == ["a", "bbb", "cc"]
    end

    test "numbers records by line, counting the blank ones it skips" do
      assert lines("a\n\n\nb\n") == [1, 4]
    end
  end

  describe "fixed-length framing" do
    test "frames every N bytes" do
      assert records("abcdef", record_length: 2) == ["ab", "cd", "ef"]
    end

    test "does not treat a line feed as a terminator" do
      assert records("ab\ncde", record_length: 2) == ["ab", "\nc", "de"]
    end

    test "numbers records in order" do
      assert lines("abcdef", record_length: 2) == [1, 2, 3]
    end

    test "reports a trailing partial record" do
      assert [{:ok, _first}, {:error, error}] = framed(["abc"], record_length: 2)

      assert %Error{reason: :record_too_short, line: 2, detail: {2, 1}} = error
      assert Exception.message(error) =~ "the record holds 1 bytes where 2 are expected"
    end

    test "reads no records from no input" do
      assert records("", record_length: 2) == []
    end
  end

  describe "comments" do
    test "discards a commented line" do
      assert records("# a note\nab\n", comment: "#") == ["ab"]
    end

    test "keeps the comment character anywhere but the start of a record" do
      assert records("a#b\n", comment: "#") == ["a#b"]
    end

    test "does not comment a fixed-length block, which has no lines" do
      assert records("#a#b", record_length: 2, comment: "#") == ["#a", "#b"]
    end
  end

  describe "byte order marks" do
    test "strips a leading byte order mark, which would shift every position" do
      assert records(<<0xEF, 0xBB, 0xBF>> <> "ab\n") == ["ab"]
    end

    test "strips one split across slices" do
      assert framed_records([<<0xEF>>, <<0xBB, 0xBF>>, "ab\n"], []) == ["ab"]
    end

    test "keeps a byte order mark that is not leading" do
      assert records("a\n" <> <<0xEF, 0xBB, 0xBF>> <> "b\n") == ["a", <<0xEF, 0xBB, 0xBF>> <> "b"]
    end
  end

  describe "slicing" do
    test "frames the same records however the input is sliced" do
      for {input, opts} <- [{"ab\r\ncd\nef\n", []}, {"abcdefgh", [record_length: 3]}] do
        expected = framed([input], opts)

        for size <- 1..byte_size(input) do
          assert framed(slice(input, size), opts) == expected,
                 "#{inspect(opts)} differs when sliced every #{size} bytes"
        end
      end
    end

    test "reads an empty slice as nothing" do
      assert framed_records(["ab", "", "\n"], []) == ["ab"]
    end
  end

  test "refuses a source that does not yield binaries" do
    assert_raise ArgumentError, ~r/expected the source to yield binaries/, fn ->
      framed([:not_a_binary], [])
    end
  end

  defp framed(slices, opts) do
    slices |> Fixed.stream(Dialect.new!(:fixed, opts)) |> Enum.to_list()
  end

  defp framed_records(slices, opts) do
    slices |> framed(opts) |> Enum.map(fn {:ok, {_line, record}} -> record end)
  end

  defp records(input, opts \\ []), do: framed_records([input], opts)

  defp lines(input, opts \\ []) do
    [input] |> framed(opts) |> Enum.map(fn {:ok, {line, _record}} -> line end)
  end

  defp slice(input, size) do
    input
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end
