Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.Memory do
  @moduledoc false

  # How much result data does `read/3` retain when a stream consumer retains no
  # rows?
  #
  # Benchee's own memory figure measures how much memory an invocation allocates
  # in total. Reading a file allocates the same rows either way, so that figure
  # does not measure the result retained after the call.
  # What differs is whether those rows are still reachable at the end. Measured
  # with Benchee, `read/3` and `stream/3` come out within a percent of each
  # other, which says nothing about the claim.
  #
  # So this script measures the size of each completed call's result.
  # `:erts_debug.size/1` walks a term and returns the words it occupies:
  # `read/3` returns every row, while `Stream.run/1` returns `:ok` after consuming
  # the stream. This measurement does not cover the parser's transient working
  # set or prove that `stream/3` holds only one slice and one row while it runs.
  # The laziness test under `stream/3` covers that contract.
  #
  # Process memory was tried first and abandoned, because a process's heap
  # capacity does not shrink promptly after a collection and the figure wanders
  # by megabytes between runs.
  #
  # Timing is left to Benchee, which is what it is good for.

  alias Delimited.Bench.Fixture
  alias Delimited.Bench.Row

  @spec run() :: Benchee.Suite.t()
  def run do
    counts = [Fixture.rows(), Fixture.rows() * 2, Fixture.rows() * 4]

    IO.puts("\nThe size of each completed call's result\n")
    IO.puts(String.pad_trailing("rows", 10) <> String.pad_trailing("read/3", 14) <> "stream/3")

    for count <- counts do
      Fixture.with_file(Fixture.plain_csv(count), fn path ->
        eager = result_size(fn -> Delimited.read!(Row, path) end)
        streamed = result_size(fn -> Row |> Delimited.stream(path) |> Stream.run() end)

        IO.puts(
          String.pad_trailing(Integer.to_string(count), 10) <>
            String.pad_trailing(megabytes(eager), 14) <> megabytes(streamed)
        )
      end)
    end

    Fixture.with_file(Fixture.plain_csv(), fn path ->
      IO.puts("\nTime, where the two should be close\n")

      Benchee.run(
        %{
          "read, every row returned" => fn -> Delimited.read!(Row, path) end,
          "stream, no rows retained" => fn ->
            Row |> Delimited.stream(path) |> Stream.run()
          end
        },
        Fixture.options("memory-time")
      )
    end)
  end

  defp result_size(work) do
    work.() |> :erts_debug.size() |> Kernel.*(:erlang.system_info(:wordsize))
  end

  defp megabytes(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 2) <> " MB"
end

Delimited.Bench.Memory.run()
