Code.require_file("support/fixture.exs", __DIR__)

defmodule Delimited.Bench.ChunkSize do
  @moduledoc false

  # Is 65_536 the right default for `:chunk_size`?
  #
  # The reader takes the file in slices of that many bytes. Too small and it
  # pays for a read and a resumption per slice; too large and it holds more than
  # it needs to and stops fitting in cache. The default was chosen without
  # evidence, so this is the evidence.
  #
  # Slice size must not change what is read — that is a property, held in
  # `test/delimited/property_test.exs`. This only asks what it costs.

  alias Delimited.Bench.Fixture
  alias Delimited.Bench.Row

  @sizes [512, 4_096, 16_384, 65_536, 262_144, 1_048_576]

  @spec run() :: Benchee.Suite.t()
  def run do
    Fixture.with_file(Fixture.plain_csv(), fn path ->
      IO.puts("#{Fixture.rows()} rows, #{div(File.stat!(path).size, 1024)} KiB\n")

      @sizes
      |> Map.new(fn size ->
        {"#{size} bytes",
         fn -> Row |> Delimited.stream(path, chunk_size: size) |> Stream.run() end}
      end)
      |> Benchee.run(Fixture.options("chunk-size"))
    end)
  end
end

Delimited.Bench.ChunkSize.run()
