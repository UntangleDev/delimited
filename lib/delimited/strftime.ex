defmodule Delimited.Strftime do
  @moduledoc false

  # Reads a date or time written in a declared format.
  #
  # Elixir can write one of these with `Calendar.strftime/3` but cannot read one
  # back, so this is the missing half. The directives are `Calendar.strftime/3`'s
  # own, which means a schema declares one format string and it serves both
  # directions: reading uses the directives compiled here, writing hands the same
  # string to the standard library.
  #
  # Only the directives that can be read back are accepted. `%A` writes a
  # weekday name that says nothing about the date, so a format using it is
  # refused when the schema compiles rather than failing on the first file.
  #
  # A format is compiled once, when the schema compiles. Reading a million rows
  # walks a list of directives rather than a format string.

  @type directive ::
          {:number, :year | :month | :day | :hour | :minute | :second, pos_integer()}
          | {:month_name, [{String.t(), pos_integer(), pos_integer()}]}
          | {:literal, binary()}

  @type compiled :: {String.t(), [directive()]}

  @months ~w(January February March April May June July August September October November December)
  @abbreviated Enum.map(@months, &binary_part(&1, 0, 3))

  # What each type must be able to work out from the text. A format that cannot
  # supply these is refused: the alternative is a date silently defaulting to
  # the first of the month.
  @required %{
    date: [:year, :month, :day],
    time: [:hour, :minute],
    naive_datetime: [:year, :month, :day, :hour, :minute],
    utc_datetime: [:year, :month, :day, :hour, :minute]
  }

  @doc """
  Compiles a format string, checking that it can be read back as `type`.

  Raises `ArgumentError`, since a format is written by a programmer and a
  mistake in one should fail the build.
  """
  @spec compile!(String.t(), atom(), atom()) :: compiled()
  def compile!(format, type, field) when is_binary(format) do
    directives = directives!(format, format, field, [])
    supplied = Enum.flat_map(directives, &supplies/1)
    missing = Enum.reject(Map.fetch!(@required, type), &(&1 in supplied))

    if missing == [] do
      {format, directives}
    else
      raise ArgumentError,
            "the :format #{inspect(format)} of field #{inspect(field)} never says the " <>
              "#{Enum.map_join(missing, ", ", &to_string/1)}, which #{inspect(type)} needs. " <>
              "A value cannot be read from a format that does not state it."
    end
  end

  defp directives!("", _format, _field, acc), do: acc |> Enum.reverse() |> merge_literals()

  defp directives!("%%" <> rest, format, field, acc),
    do: directives!(rest, format, field, [{:literal, "%"} | acc])

  defp directives!("%" <> <<letter, rest::binary>>, format, field, acc) do
    directives!(rest, format, field, [directive!(letter, format, field) | acc])
  end

  defp directives!(<<byte, rest::binary>>, format, field, acc),
    do: directives!(rest, format, field, [{:literal, <<byte>>} | acc])

  defp directive!(?Y, _format, _field), do: {:number, :year, 4}
  defp directive!(?y, _format, _field), do: {:number, :short_year, 2}
  defp directive!(?m, _format, _field), do: {:number, :month, 2}
  defp directive!(?d, _format, _field), do: {:number, :day, 2}
  defp directive!(?H, _format, _field), do: {:number, :hour, 2}
  defp directive!(?M, _format, _field), do: {:number, :minute, 2}
  defp directive!(?S, _format, _field), do: {:number, :second, 2}
  defp directive!(?B, _format, _field), do: {:month_name, comparable(@months)}
  defp directive!(?b, _format, _field), do: {:month_name, comparable(@abbreviated)}

  defp directive!(letter, format, field) do
    raise ArgumentError,
          "the :format #{inspect(format)} of field #{inspect(field)} uses %#{<<letter>>}, " <>
            "which cannot be read back. The directives that can are " <>
            "%Y %y %m %d %H %M %S %B %b and %%, and any other character matches itself."
  end

  # Month names are folded and measured once, when the schema compiles, rather
  # than for every name of every row.
  defp comparable(names) do
    names
    |> Enum.with_index(1)
    |> Enum.map(fn {name, month} -> {String.downcase(name), byte_size(name), month} end)
  end

  # Adjacent literals become one, so that matching a separator is a single
  # binary comparison rather than one per byte.
  defp merge_literals([{:literal, left}, {:literal, right} | rest]),
    do: merge_literals([{:literal, left <> right} | rest])

  defp merge_literals([directive | rest]), do: [directive | merge_literals(rest)]
  defp merge_literals([]), do: []

  defp supplies({:number, :short_year, _width}), do: [:year]
  defp supplies({:number, part, _width}), do: [part]
  defp supplies({:month_name, _names}), do: [:month]
  defp supplies({:literal, _text}), do: []

  @doc """
  Reads `text` as `type`, trying each compiled format in turn.

  Returns `:error` if none of them reads the whole of it.
  """
  @spec parse([compiled()], String.t(), atom()) :: {:ok, term()} | :error
  def parse(formats, text, type) do
    Enum.reduce_while(formats, :error, fn {_format, directives}, _unread ->
      with {:ok, parts} <- read(directives, text, %{}),
           {:ok, value} <- build(type, parts) do
        {:halt, {:ok, value}}
      else
        :error -> {:cont, :error}
      end
    end)
  end

  defp read([], "", parts), do: {:ok, parts}
  defp read([], _rest, _parts), do: :error

  defp read([{:literal, text} | directives], input, parts) do
    size = byte_size(text)

    case input do
      <<candidate::binary-size(^size), rest::binary>> when candidate == text ->
        read(directives, rest, parts)

      _other ->
        :error
    end
  end

  defp read([{:number, part, width} | directives], input, parts) do
    case take_digits(input, width, 0, 0) do
      {:ok, value, rest} -> read(directives, rest, Map.put(parts, part, value))
      :error -> :error
    end
  end

  defp read([{:month_name, names} | directives], input, parts) do
    case month_of(names, input) do
      {month, rest} -> read(directives, rest, Map.put(parts, :month, month))
      :error -> :error
    end
  end

  defp month_of(names, input) do
    Enum.find_value(names, :error, fn name -> named_month(name, input) end)
  end

  defp named_month({lowered, size, month}, input) do
    case input do
      <<candidate::binary-size(^size), rest::binary>> ->
        if String.downcase(candidate) == lowered, do: {month, rest}

      _other ->
        nil
    end
  end

  # Digits are taken greedily up to the directive's width, so that a format
  # writing "01" also reads "1" where a separator follows, while a format with
  # no separators still divides its fields correctly.
  defp take_digits(input, 0, value, _taken), do: {:ok, value, input}

  defp take_digits(<<digit, rest::binary>>, width, value, taken) when digit in ?0..?9 do
    take_digits(rest, width - 1, value * 10 + (digit - ?0), taken + 1)
  end

  defp take_digits(_input, _width, _value, 0), do: :error
  defp take_digits(input, _width, value, _taken), do: {:ok, value, input}

  defp build(:date, parts), do: wrap(Date.new(year(parts), parts.month, parts.day))

  defp build(:time, parts),
    do: wrap(Time.new(parts.hour, parts.minute, Map.get(parts, :second, 0)))

  defp build(:naive_datetime, parts), do: wrap(naive(parts))

  defp build(:utc_datetime, parts) do
    with {:ok, naive} <- naive(parts),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, datetime}
    else
      _other -> :error
    end
  end

  defp naive(parts) do
    NaiveDateTime.new(
      year(parts),
      parts.month,
      parts.day,
      parts.hour,
      parts.minute,
      Map.get(parts, :second, 0)
    )
  end

  # The POSIX window for a two-digit year. Any rule here is a guess about a
  # century the file did not state; this is the guess `strptime` makes, and it
  # is documented rather than hidden.
  defp year(%{year: year}), do: year
  defp year(%{short_year: year}) when year >= 69, do: 1900 + year
  defp year(%{short_year: year}), do: 2000 + year

  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap({:error, _reason}), do: :error
end
