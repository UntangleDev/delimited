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
      it must already be a value of the field's type.

    * `:required` - when `true`, an empty cell is a `:required_field_missing`
      error instead of `nil`. Defaults to `false`. A required field cannot also
      declare a default, because the default would make the requirement
      unreachable.

    * `:trim` - strip surrounding whitespace from the cell before reading it.
      Defaults to the dialect's `:trim`.

    * `:null` - the strings that mean "no value" for this field. Defaults to the
      dialect's `:null`. Use it for the file that writes `"N/A"` in one column
      and leaves the rest blank.

  Any other option is passed to a custom type. Built-in types reject unknown
  options, so a misspelt `:heder` fails the build rather than reading the wrong
  column.
  """

  alias Delimited.Type

  @enforce_keys [:name, :type, :header]
  defstruct [:name, :type, :header, :default, :trim, :null, required: false, opts: []]

  @type t :: %__MODULE__{
          name: atom(),
          type: Type.t(),
          header: String.t(),
          default: term(),
          trim: boolean() | nil,
          null: [String.t()] | nil,
          required: boolean(),
          opts: keyword()
        }

  @own_options [:header, :default, :required, :trim, :null]

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
      opts: type_options!(name, type, rest)
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
