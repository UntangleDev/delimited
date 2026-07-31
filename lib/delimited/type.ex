defmodule Delimited.Type do
  @moduledoc """
  The built-in field types and the behaviour for defining your own.

  A type is the only place where the text in a file becomes an Elixir term.
  Reading calls `c:cast/2` with the cell's text; writing calls `c:dump/2` with
  the term. Neither callback ever receives `nil`: an empty cell becomes the
  field's default without reaching the type, and a `nil` value is written as the
  dialect's first null string.

  ## Built-in types

  | Type | Reads | Writes |
  |---|---|---|
  | `:string` | the cell unchanged | the binary unchanged |
  | `:integer` | an optionally signed decimal integer | `Integer.to_string/1` |
  | `:float` | an integer or decimal, with an optional exponent | `Float.to_string/1` |
  | `:boolean` | `true`/`t`/`yes`/`y`/`1` and `false`/`f`/`no`/`n`/`0`, any case | `"true"` or `"false"` |
  | `:date` | `Date.from_iso8601/1` | `Date.to_iso8601/1` |
  | `:time` | `Time.from_iso8601/1` | `Time.to_iso8601/1` |
  | `:naive_datetime` | `NaiveDateTime.from_iso8601/1` | `NaiveDateTime.to_iso8601/1` |
  | `:utc_datetime` | `DateTime.from_iso8601/1`, converted to UTC | `DateTime.to_iso8601/1` |
  | `:decimal` | `Decimal.parse/1`, finite values only | `Decimal.to_string/2` in `:normal` form |
  | `{:enum, values}` | one of the declared strings | the string declared for the term |

  The whole cell must be consumed. `"12abc"` is not an integer and `"1.0"` is
  not an integer, because a partial read is how silently wrong numbers enter a
  data set.

  `:utc_datetime` accepts any ISO 8601 offset and converts to UTC, so
  `2024-03-01T12:00:00+02:00` reads as `2024-03-01 10:00:00Z`. Writing it back
  produces the UTC form, not the original offset.

  `:decimal` requires the optional `:decimal` dependency, at any 2.x or 3.x
  version. Declaring the type without it raises at compile time.

  Which of those you resolve decides what happens to a hostile number, so it is
  worth choosing rather than inheriting. Decimal 3.0 made the IEEE 754
  decimal128 limits its defaults, mitigating
  [CVE-2026-32686](https://nvd.nist.gov/vuln/detail/CVE-2026-32686): a cell
  holding `1e1000000000` is refused as it is read. Every 2.x version accepts
  that cell, and writing the value back renders it in full, at a length that
  grows with the exponent, which a file you do not control can therefore use to
  exhaust memory. Require `{:decimal, "~> 3.0"}` if you read files from
  anywhere you do not trust.

  No built-in type parses a locale-specific date, a thousands separator, or a
  currency symbol. Define a type for those.

  ## Enumerations

  `{:enum, [:draft, :published]}` reads and writes the atom's own text.
  `{:enum, [draft: "D", published: "P"]}` maps each atom to the text the file
  uses. Any other text in the cell is a `:cast_failed` error, which is the point
  of declaring the enumeration.

  ## Defining a type

      defmodule Postcode do
        @behaviour Delimited.Type

        @impl true
        def cast(text, _opts) do
          case Regex.run(~r/^([A-Z]{1,2}\\d[A-Z\\d]?) ?(\\d[A-Z]{2})$/, String.upcase(text)) do
            [_, outward, inward] -> {:ok, outward <> " " <> inward}
            nil -> {:error, "a UK postcode"}
          end
        end

        @impl true
        def dump(postcode, _opts) when is_binary(postcode), do: {:ok, postcode}
        def dump(_other, _opts), do: {:error, "a UK postcode"}
      end

  Use it as `field :postcode, Postcode`. The error string completes the sentence
  "cannot read _value_ as ...", so write a noun phrase rather than a sentence.

  Options that `Delimited.Field` does not recognise are passed to a custom type
  as `opts`, so `field :price, Money, currency: "GBP"` reaches `cast/2` as
  `[currency: "GBP"]`. Built-in types accept no options and reject unknown ones,
  because there a stray key is a typo rather than configuration.
  """

  @typedoc "A built-in type name, an enumeration, or a module implementing this behaviour."
  @type t ::
          :string
          | :integer
          | :float
          | :boolean
          | :date
          | :time
          | :naive_datetime
          | :utc_datetime
          | :decimal
          | {:enum, [{atom(), String.t()}]}
          | module()

  @typedoc "What the type expected, as a noun phrase completing \"cannot read X as ...\"."
  @type expectation :: String.t()

  @doc """
  Converts one cell's text into a term.

  Never called with `nil`. Return `{:error, expectation}` where the expectation
  completes the sentence "cannot read _value_ as ...".
  """
  @callback cast(text :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, expectation()}

  @doc """
  Converts a term into the text for one cell.

  Never called with `nil`. Returning iodata avoids a copy for composite values.
  """
  @callback dump(value :: term(), opts :: keyword()) ::
              {:ok, iodata()} | {:error, expectation()}

  @builtins [
    :string,
    :integer,
    :float,
    :boolean,
    :date,
    :time,
    :naive_datetime,
    :utc_datetime,
    :decimal
  ]

  @decimal_available? Code.ensure_loaded?(Decimal)

  if not @decimal_available? do
    @decimal_missing "the :decimal type needs the optional :decimal dependency. " <>
                       "Add {:decimal, \"~> 2.0\"} to deps/0, or use :float or :string."
  end

  @true_words ~w(true t yes y 1)
  @false_words ~w(false f no n 0)

  @doc """
  Returns the built-in type names.
  """
  @spec builtins() :: [atom()]
  def builtins, do: @builtins

  @doc """
  Checks a declared type and returns it in the form the reader and writer use.

  Enumerations are normalised to a keyword list of term-to-text pairs, so
  `{:enum, [:a]}` becomes `{:enum, [a: "a"]}`. Every other type is returned
  unchanged.

  Raises `ArgumentError` for an unknown type. Called at compile time by the
  schema DSL, so a typo fails the build rather than the first read.
  """
  @spec validate!(term()) :: t()
  if not @decimal_available? do
    def validate!(:decimal), do: raise(ArgumentError, @decimal_missing)
  end

  def validate!(type) when type in @builtins, do: type

  def validate!({:enum, values}) when is_list(values) and values != [] do
    {:enum, Enum.map(values, &validate_enum_value!(&1, values))}
  end

  def validate!(module) when is_atom(module) do
    if module_name?(module) do
      module
    else
      raise ArgumentError,
            "unknown type #{inspect(module)}. Use one of #{inspect(@builtins)}, " <>
              "{:enum, values}, or a module implementing the Delimited.Type behaviour."
    end
  end

  def validate!(other) do
    raise ArgumentError,
          "unknown type #{inspect(other)}. Use one of #{inspect(@builtins)}, " <>
            "{:enum, values}, or a module implementing the Delimited.Type behaviour."
  end

  @doc """
  Describes what a type accepts, as a noun phrase.
  """
  @spec describe(t()) :: expectation()
  def describe(:string), do: "text"
  def describe(:integer), do: "a whole number"
  def describe(:float), do: "a number"
  def describe(:boolean), do: "a boolean (#{words(@true_words)} or #{words(@false_words)})"
  def describe(:date), do: "a date in ISO 8601 form (YYYY-MM-DD)"
  def describe(:time), do: "a time in ISO 8601 form (hh:mm:ss)"
  def describe(:naive_datetime), do: "a date and time in ISO 8601 form"
  def describe(:utc_datetime), do: "a date and time in ISO 8601 form, with or without an offset"
  def describe(:decimal), do: "a finite decimal number"
  def describe({:enum, values}), do: "one of #{words(Enum.map(values, &elem(&1, 1)))}"
  def describe(module) when is_atom(module), do: "a value #{inspect(module)} accepts"

  @doc """
  Reads one cell's text as `type`.
  """
  @spec cast(t(), String.t(), keyword()) :: {:ok, term()} | {:error, expectation()}
  def cast(:string, text, _opts), do: {:ok, text}

  def cast(:integer, text, _opts) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, describe(:integer)}
    end
  end

  def cast(:float, text, _opts) do
    case Float.parse(text) do
      {float, ""} -> {:ok, float}
      _other -> {:error, describe(:float)}
    end
  end

  def cast(:boolean, text, _opts) do
    case String.downcase(text) do
      word when word in @true_words -> {:ok, true}
      word when word in @false_words -> {:ok, false}
      _other -> {:error, describe(:boolean)}
    end
  end

  def cast(:date, text, _opts), do: wrap(Date.from_iso8601(text), :date)
  def cast(:time, text, _opts), do: wrap(Time.from_iso8601(text), :time)

  def cast(:naive_datetime, text, _opts),
    do: wrap(NaiveDateTime.from_iso8601(text), :naive_datetime)

  def cast(:utc_datetime, text, _opts) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, describe(:utc_datetime)}
    end
  end

  def cast(:decimal, text, _opts), do: cast_decimal(text)

  def cast({:enum, values}, text, _opts) do
    case List.keyfind(values, text, 1) do
      {term, ^text} -> {:ok, term}
      nil -> {:error, describe({:enum, values})}
    end
  end

  def cast(module, text, opts) when is_atom(module), do: module.cast(text, opts)

  @doc """
  Writes a term as one cell's text.
  """
  @spec dump(t(), term(), keyword()) :: {:ok, iodata()} | {:error, expectation()}
  def dump(:string, value, _opts) when is_binary(value), do: {:ok, value}
  def dump(:integer, value, _opts) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def dump(:float, value, _opts) when is_float(value), do: {:ok, Float.to_string(value)}
  def dump(:float, value, _opts) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def dump(:boolean, true, _opts), do: {:ok, "true"}
  def dump(:boolean, false, _opts), do: {:ok, "false"}
  def dump(:date, %Date{} = value, _opts), do: {:ok, Date.to_iso8601(value)}
  def dump(:time, %Time{} = value, _opts), do: {:ok, Time.to_iso8601(value)}

  def dump(:naive_datetime, %NaiveDateTime{} = value, _opts),
    do: {:ok, NaiveDateTime.to_iso8601(value)}

  def dump(:utc_datetime, %DateTime{} = value, _opts), do: {:ok, DateTime.to_iso8601(value)}
  def dump(:decimal, value, _opts) when is_struct(value), do: dump_decimal(value)

  def dump({:enum, values}, value, _opts) do
    case List.keyfind(values, value, 0) do
      {^value, text} -> {:ok, text}
      nil -> {:error, describe({:enum, values})}
    end
  end

  def dump(module, value, opts) when is_atom(module) and module not in @builtins,
    do: module.dump(value, opts)

  def dump(type, _value, _opts), do: {:error, describe(type)}

  if @decimal_available? do
    defp cast_decimal(text) do
      # Decimal.parse/1 accepts "NaN" and "Infinity". Neither is a measurement,
      # so both are refused here rather than propagated into arithmetic.
      case Decimal.parse(text) do
        {%{coef: coefficient} = decimal, ""} when is_integer(coefficient) -> {:ok, decimal}
        _other -> {:error, describe(:decimal)}
      end
    end

    defp dump_decimal(%Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
    defp dump_decimal(_other), do: {:error, describe(:decimal)}
  else
    defp cast_decimal(_text), do: raise(ArgumentError, @decimal_missing)
    defp dump_decimal(_value), do: raise(ArgumentError, @decimal_missing)
  end

  defp wrap({:ok, value}, _type), do: {:ok, value}
  defp wrap({:error, _reason}, type), do: {:error, describe(type)}

  defp words(list), do: Enum.map_join(list, ", ", &inspect/1)

  defp validate_enum_value!(term, _values) when is_atom(term) and not is_nil(term),
    do: {term, Atom.to_string(term)}

  defp validate_enum_value!({term, text}, _values) when is_atom(term) and is_binary(text),
    do: {term, text}

  defp validate_enum_value!(other, values) do
    raise ArgumentError,
          "invalid enumeration value #{inspect(other)} in #{inspect({:enum, values})}. " <>
            "Give a list of atoms, or a keyword list mapping each atom to its text."
  end

  defp module_name?(module) do
    case Atom.to_string(module) do
      "Elixir." <> _rest -> true
      _other -> false
    end
  end
end
