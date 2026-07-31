defmodule Delimited.Fixed do
  @moduledoc false

  # Frames a byte stream into fixed-width records.
  #
  # The counterpart of `Delimited.Parser` for `layout: :fixed`. It does far less
  # work, because a fixed-width file has no quoting and therefore no way for a
  # record to contain its own terminator: framing is either "up to the next line
  # feed" or "the next N bytes", and nothing about the record's contents can
  # change that.
  #
  # It yields the record's bytes rather than cells. Which bytes belong to which
  # field is the schema's business, and a file holding several record shapes
  # cannot know which schema applies until it has read the discriminator out of
  # the raw record.
  #
  # Like the parser, it accepts input in arbitrary slices and reads the same
  # records however the slices fall. A record is emitted only once its whole
  # extent has arrived, so nothing depends on where a slice ends.
  #
  # A leading byte order mark is stripped. Left in place it would shift every
  # declared position by three bytes, which is the silent corruption this layout
  # is most exposed to.

  alias Delimited.Dialect
  alias Delimited.Error

  defstruct [:record_length, :skip_blank_lines, buffer: "", line: 1, bom_pending?: true]

  @type framed :: {pos_integer(), binary()}
  @opaque t :: %__MODULE__{}

  @bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Builds the initial state for a dialect.
  """
  @spec new(Dialect.t()) :: t()
  def new(%Dialect{} = dialect) do
    %__MODULE__{
      record_length: dialect.record_length,
      skip_blank_lines: dialect.skip_blank_lines
    }
  end

  @doc """
  Consumes one slice of input, returning the records it completed.
  """
  @spec parse(t(), binary()) :: {:ok, [framed()], t()}
  def parse(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    state = %{state | buffer: state.buffer <> chunk}

    case handle_bom(state) do
      {:incomplete, state} -> {:ok, [], state}
      {:ok, state} -> frame(state, [])
    end
  end

  @doc """
  Closes the input, returning any record left in the buffer.

  Under line framing a final record without a terminator is a record. Under
  fixed-length framing it is a truncated file, because a record there is defined
  by its length.
  """
  @spec finish(t()) :: {:ok, [framed()]} | {:error, Error.t()}
  def finish(%__MODULE__{buffer: ""}), do: {:ok, []}

  def finish(%__MODULE__{record_length: :line} = state) do
    {:ok, emit(state, strip_carriage_return(state.buffer), state.line, [])}
  end

  def finish(%__MODULE__{} = state) do
    {:error,
     Error.new(:record_too_short,
       line: state.line,
       detail: {state.record_length, byte_size(state.buffer)}
     )}
  end

  # A byte order mark can be split across slices, so an incomplete prefix waits
  # in the buffer rather than being read as the first bytes of a record.
  defp handle_bom(%{bom_pending?: false} = state), do: {:ok, state}

  defp handle_bom(%{buffer: @bom <> rest} = state),
    do: {:ok, %{state | buffer: rest, bom_pending?: false}}

  defp handle_bom(%{buffer: buffer} = state) when byte_size(buffer) >= 3,
    do: {:ok, %{state | bom_pending?: false}}

  defp handle_bom(%{buffer: buffer} = state) do
    if :binary.longest_common_prefix([@bom, buffer]) == byte_size(buffer) do
      {:incomplete, state}
    else
      {:ok, %{state | bom_pending?: false}}
    end
  end

  defp frame(%{record_length: :line} = state, records) do
    case :binary.match(state.buffer, "\n") do
      :nomatch ->
        {:ok, Enum.reverse(records), state}

      {position, 1} ->
        record = state.buffer |> binary_part(0, position) |> strip_carriage_return()
        rest = advance(state.buffer, position + 1)

        frame(
          %{state | buffer: rest, line: state.line + 1},
          emit(state, record, state.line, records)
        )
    end
  end

  defp frame(%{record_length: length, buffer: buffer} = state, records)
       when is_integer(length) and byte_size(buffer) >= length do
    record = binary_part(buffer, 0, length)

    frame(
      %{state | buffer: advance(buffer, length), line: state.line + 1},
      [{state.line, record} | records]
    )
  end

  defp frame(state, records), do: {:ok, Enum.reverse(records), state}

  # An entirely empty line holds no record. A line of spaces is not empty: under
  # this layout it is a record whose every field is blank.
  defp emit(%{skip_blank_lines: true}, "", _line, records), do: records
  defp emit(_state, record, line, records), do: [{line, record} | records]

  defp strip_carriage_return(""), do: ""

  defp strip_carriage_return(record) do
    size = byte_size(record)

    case binary_part(record, size - 1, 1) do
      "\r" -> binary_part(record, 0, size - 1)
      _other -> record
    end
  end

  defp advance(binary, position), do: binary_part(binary, position, byte_size(binary) - position)

  @doc """
  Reads a stream of slices as a stream of records.
  """
  @spec stream(Enumerable.t(), Dialect.t()) ::
          Enumerable.t({:ok, framed()} | {:error, Error.t()})
  def stream(chunks, %Dialect{} = dialect) do
    chunks
    |> Stream.concat([:end_of_input])
    |> Stream.transform({:framing, new(dialect)}, &step/2)
  end

  defp step(_element, :halted), do: {:halt, :halted}

  defp step(:end_of_input, {:framing, state}) do
    case finish(state) do
      {:ok, records} -> {Enum.map(records, &{:ok, &1}), :halted}
      {:error, error} -> {[{:error, error}], :halted}
    end
  end

  defp step(chunk, {:framing, state}) when is_binary(chunk) do
    {:ok, records, state} = parse(state, chunk)

    {Enum.map(records, &{:ok, &1}), {:framing, state}}
  end

  defp step(other, {:framing, _state}) do
    raise ArgumentError,
          "expected the source to yield binaries, got: #{inspect(other)}. " <>
            "Read a file with a path, or pass a stream of binary slices."
  end
end
