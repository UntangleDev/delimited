defmodule Delimited.Field do
  @moduledoc """
  One declared column.

  Built by `Delimited.Schema.field/3` at compile time. Read it back with
  `MySchema.__delimited__(:fields)` when you need to generate documentation, a
  template file, or a user-facing column list.

  ## Options

    * `:header` - the column name in the file. Defaults to the field name.
      Set it whenever the file's spelling is not a valid atom, which is most
      real files: `field :employee_id, :integer, header: "Employee ID"`.

    * `:default` - the term used when the cell is empty or the column is absent.
      Defaults to `nil`. The default is used as declared and is never cast, so
      it must already be a value of the field's type. Writing `nil` is refused
      when reading the resulting null cell would return a non-nil default.

    * `:required` - when `true`, an empty cell is a `:required_field_missing`
      error instead of `nil`. Defaults to `false`. A required field cannot also
      declare a default, because the default would make the requirement
      unreachable.

    * `:trim` - strip surrounding whitespace from the cell before reading it.
      Defaults to the dialect's `:trim`. The writer refuses text that this rule
      would change.

    * `:null` - the strings that mean "no value" for this field. Defaults to the
      dialect's `:null`. Use it for the file that writes `"N/A"` in one column
      and leaves the rest blank. The writer refuses a non-nil value whose text
      is one of these strings.

    * `:format` - how a date or time is written, where the file does not use
      ISO 8601: `field :invoiced_on, :date, format: "%d/%m/%Y"`. Give a list to
      read more than one spelling. Only `:date`, `:time`, `:naive_datetime`, and
      `:utc_datetime` accept it. See `Delimited.Type` for the directives.

  Any other option is passed to a custom type. Built-in types reject unknown
  options, so a misspelt `:heder` fails the build rather than reading the wrong
  column.

  ## Fixed-width options

  Under `layout: :fixed` a field is a byte range rather than a cell, and these
  three options decide which bytes and how they are padded. They are rejected
  under the delimited layout, where nothing could honour them.

    * `:at` - the field's position as a **1-based, inclusive** range, as a file
      specification writes it: a field documented as "positions 8-15" is
      `at: 8..15`. Required under the fixed layout. Positions not covered by any
      field are filler, and are neither read nor written.

    * `:align` - which end of the field the value sits at: `:left` pads on the
      right, `:right` pads on the left. Defaults to `:right` for `:integer`,
      `:float`, and `:decimal`, and to `:left` for everything else, which is
      what specifications almost always mean. Declare it where yours does not.

    * `:pad` - the byte that fills the rest of the field, as a one-character
      string or a codepoint. Defaults to a space.

  ### Reading a padded field

  Pad bytes are stripped from the padded side, and the value then goes through
  `:trim`, `:null`, and its type as any other cell does. A space-padded field
  holding only spaces therefore has no value, because the empty string is the
  default null string.

  A field padded with anything else has to distinguish two cases, and does:

    * `"00000000"` in a zero-padded numeric field reads as `0`. The field keeps
      its last pad byte, because stripping it to nothing would turn a stated
      zero into a missing value and no later check would reveal it.
    * `"        "` in that same field reads as `nil`. A file that fills a
      numeric field with digits when it has a number leaves it blank when it has
      none, so spaces where digits were expected mean absent rather than zero.

  ### Writing a padded field

  A value is padded with the field's `:pad`. A field holding `nil` is left
  blank, whatever its `:pad`, which is the counterpart of the rule above: an
  empty field filled with zeros would state a number the row never held. The
  writer refuses `nil` if the field is required or if reading a blank field
  would return a non-nil default.

  A value wider than its field is a `:value_too_wide` error. Truncating it would
  produce a file that parses and lies.

  A type must be able to write itself narrow enough. `:boolean` writes `"true"`
  and `"false"`, so a one-character flag column wants
  `{:enum, [true: "Y", false: "N"]}` rather than `:boolean`.
  """

  alias Delimited.Strftime
  alias Delimited.Type

  @enforce_keys [:name, :type, :header]
  defstruct [
    :name,
    :type,
    :header,
    :default,
    :trim,
    :null,
    :at,
    :align,
    :pad,
    required: false,
    opts: []
  ]

  @typedoc "A field's position as a zero-based byte offset and a length."
  @type position :: {non_neg_integer(), pos_integer()}

  @type t :: %__MODULE__{
          name: atom(),
          type: Type.t(),
          header: String.t(),
          default: term(),
          trim: boolean() | nil,
          null: [String.t()] | nil,
          at: position() | nil,
          align: :left | :right | nil,
          pad: byte() | nil,
          required: boolean(),
          opts: keyword()
        }

  # An option left undeclared is stored as nil rather than resolved here, so
  # that Delimited.Schema can tell "not declared" from "declared as the default"
  # when it checks a field against its layout.
  @own_options [:header, :default, :required, :trim, :null, :at, :align, :pad, :format]

  @temporal_types [:date, :time, :naive_datetime, :utc_datetime]

  @right_aligned_types [:integer, :float, :decimal]

  @doc false
  @spec new!(atom(), term(), keyword()) :: t()
  def new!(name, type, opts) when is_atom(name) and not is_nil(name) and is_list(opts) do
    type = Type.validate!(type)
    {own, rest} = Keyword.split(opts, @own_options)

    %__MODULE__{
      name: name,
      type: type,
      header: header!(name, own),
      default: Keyword.get(own, :default),
      required: required!(name, own),
      trim: boolean_or_nil!(name, :trim, own),
      null: null!(name, own),
      at: at!(name, own),
      align: align!(name, own),
      pad: pad!(name, own),
      opts: type_options!(name, type, rest) ++ format!(name, type, own)
    }
  end

  def new!(name, _type, opts) do
    raise ArgumentError,
          "expected `field name, type, options` with an atom name and a keyword list " <>
            "of options, got name #{inspect(name)} and options #{inspect(opts)}"
  end

  defp header!(name, own) do
    case Keyword.get(own, :header, Atom.to_string(name)) do
      header when is_binary(header) and header != "" ->
        header

      other ->
        raise ArgumentError,
              "the :header of field #{inspect(name)} must be a non-empty string, " <>
                "got: #{inspect(other)}"
    end
  end

  defp required!(name, own) do
    required = boolean_or_nil!(name, :required, own) || false

    if required and Keyword.has_key?(own, :default) do
      raise ArgumentError,
            "field #{inspect(name)} is required and also declares a default. " <>
              "A default is used whenever the cell is empty, so the requirement " <>
              "could never fail. Keep one of them."
    end

    required
  end

  defp null!(name, own) do
    case Keyword.get(own, :null) do
      nil ->
        nil

      list when is_list(list) ->
        Enum.each(list, fn
          string when is_binary(string) ->
            :ok

          other ->
            raise ArgumentError,
                  "the :null strings of field #{inspect(name)} must be strings, " <>
                    "got: #{inspect(other)}"
        end)

        list

      other ->
        raise ArgumentError,
              "the :null option of field #{inspect(name)} must be a list of strings, " <>
                "got: #{inspect(other)}"
    end
  end

  # Declared 1-based and inclusive to match a file specification; stored
  # zero-based with a length, which is what binary_part/3 takes.
  defp at!(name, own) do
    case Keyword.get(own, :at) do
      nil ->
        nil

      %Range{first: first, last: last, step: 1} when first >= 1 and last >= first ->
        {first - 1, last - first + 1}

      other ->
        raise ArgumentError,
              "the :at of field #{inspect(name)} must be a 1-based inclusive range of " <>
                "byte positions, ascending, such as 8..15, got: #{inspect(other)}"
    end
  end

  defp align!(name, own) do
    case Keyword.get(own, :align) do
      nil -> nil
      align when align in [:left, :right] -> align
      other -> raise ArgumentError, alignment_error(name, other)
    end
  end

  defp pad!(name, own) do
    case Keyword.get(own, :pad) do
      nil -> nil
      <<byte>> when byte < 128 -> byte
      byte when is_integer(byte) and byte in 0..127 -> byte
      other -> raise ArgumentError, pad_error(name, other)
    end
  end

  defp alignment_error(name, value) do
    "the :align of field #{inspect(name)} must be :left or :right, got: #{inspect(value)}"
  end

  defp pad_error(name, value) do
    "the :pad of field #{inspect(name)} must be a single ASCII character, given as a " <>
      "one-character string or a codepoint, got: #{inspect(value)}. A multi-byte pad " <>
      "character would make the field's width in bytes differ from its width on screen."
  end

  @doc """
  Returns the field's alignment, resolving the default from its type.
  """
  @spec alignment(t()) :: :left | :right
  def alignment(%__MODULE__{align: align}) when not is_nil(align), do: align
  def alignment(%__MODULE__{type: type}) when type in @right_aligned_types, do: :right
  def alignment(%__MODULE__{}), do: :left

  @doc """
  Returns the field's pad byte, which defaults to a space.
  """
  @spec padding(t()) :: byte()
  def padding(%__MODULE__{pad: nil}), do: ?\s
  def padding(%__MODULE__{pad: pad}), do: pad

  @doc """
  Returns the position one past the field's last byte.
  """
  @spec ends_at(t()) :: non_neg_integer()
  def ends_at(%__MODULE__{at: {offset, length}}), do: offset + length

  @doc """
  Returns the field's declared position as it was written, for a message.
  """
  @spec declared_at(t()) :: Range.t()
  def declared_at(%__MODULE__{at: {offset, length}}), do: (offset + 1)..(offset + length)

  # Compiled here rather than on first use, so that an unreadable format fails
  # the build instead of every row of the first file.
  defp format!(name, type, own) do
    case Keyword.get(own, :format) do
      nil ->
        []

      _formats when type not in @temporal_types ->
        raise ArgumentError,
              "field #{inspect(name)} declares a :format, which only #{inspect(@temporal_types)} " <>
                "can use. A type of its own is the place to read anything else that the " <>
                "file writes in a shape of its own."

      formats ->
        [format: formats |> List.wrap() |> Enum.map(&Strftime.compile!(&1, type, name))]
    end
  end

  defp boolean_or_nil!(_name, key, own) when is_atom(key) do
    case Keyword.get(own, key) do
      value when is_boolean(value) or is_nil(value) ->
        value

      other ->
        raise ArgumentError, "#{inspect(key)} must be true or false, got: #{inspect(other)}"
    end
  end

  defp type_options!(_name, _type, []), do: []

  defp type_options!(name, type, rest) when is_atom(type) do
    if type in Type.builtins() do
      raise ArgumentError, unknown_options(name, rest)
    else
      rest
    end
  end

  defp type_options!(name, _type, rest), do: raise(ArgumentError, unknown_options(name, rest))

  defp unknown_options(name, rest) do
    "unknown option#{if length(rest) > 1, do: "s"} " <>
      "#{Enum.map_join(rest, ", ", fn {key, _value} -> inspect(key) end)} " <>
      "on field #{inspect(name)}. Field options are #{inspect(@own_options)}. " <>
      "Only a custom type module receives further options."
  end
end
