Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.Memory do
  @moduledoc false

  # Does `stream/3` actually hold one row at a time?
  #
  # Benchee's own memory figure will not answer this, and it is worth saying why
  # rather than quietly not using it: it measures how much memory an invocation
  # allocates in total, and reading a file allocates the same rows either way.
  # What differs is whether those rows are still reachable at the end. Measured
  # with Benchee, `read/3` and `stream/3` come out within a percent of each
  # other, which says nothing about the claim.
  #
  # So retention is measured as the size of what each one hands back.
  # `:erts_debug.size/1` walks a term and returns the words it occupies, which
  # is exactly the question: `read/3` returns every row, so it grows with the
  # file; `stream/3` returns `:ok`, so it does not. Process memory was tried
  # first and abandoned, because a process's heap capacity does not shrink
  # promptly after a collection and the figure wanders by megabytes between runs.
  #
  # Timing is left to Benchee, which is what it is good for.

  alias Delimited.Bench.Fixture
  alias Delimited.Bench.Row

  def run do
    counts = [Fixture.rows(), Fixture.rows() * 2, Fixture.rows() * 4]

    IO.puts("\nThe size of what each one hands back\n")
    IO.puts(String.pad_trailing("rows", 10) <> String.pad_trailing("read/3", 14) <> "stream/3")

    for count <- counts do
      Fixture.with_file(Fixture.plain_csv(count), fn path ->
        eager = retained(fn -> Delimited.read!(Row, path) end)
        lazy = retained(fn -> Row |> Delimited.stream(path) |> Stream.run() end)

        IO.puts(
          String.pad_trailing(Integer.to_string(count), 10) <>
            String.pad_trailing(megabytes(eager), 14) <> megabytes(lazy)
        )
      end)
    end

    Fixture.with_file(Fixture.plain_csv(), fn path ->
      IO.puts("\nTime, where the two should be close\n")

      Benchee.run(
        %{
          "read, every row held" => fn -> Delimited.read!(Row, path) end,
          "stream, one row at a time" => fn ->
            Row |> Delimited.stream(path) |> Stream.run()
          end
        },
        Fixture.options()
      )
    end)
  end

  defp retained(work) do
    work.() |> :erts_debug.size() |> Kernel.*(:erlang.system_info(:wordsize))
  end

  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 2) <> " MB"
end

Delimited.Bench.Memory.run()
