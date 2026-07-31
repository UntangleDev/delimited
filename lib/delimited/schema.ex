defmodule Delimited.Schema do
  @moduledoc """
  Declares the columns of a delimited file as a struct.

      defmodule Employee do
        use Delimited.Schema

        delimited_schema do
          field :id, :integer, header: "Employee ID"
          field :name, :string, required: true
          field :department, {:enum, [engineering: "ENG", sales: "SLS"]}
          field :hired_on, :date, header: "Hire Date"
          field :salary, :decimal
          field :active, :boolean, default: true
        end
      end

  The module gains a struct with one key per field, and `Delimited` gains
  everything it needs to read and write that file. A schema holds no behaviour
  of its own: `Delimited.read/3` and `Delimited.write/4` take the module the way
  an `Ecto.Repo` takes an `Ecto.Schema`.

  ## What the declaration decides

  The order of `field/3` calls is the order of columns when writing, and the
  order columns are matched in when reading with `headers: false`. When reading
  with headers, order is irrelevant and only the `:header` name matters.

  A field's name is the struct key. Its `:header` is the text in the file, and
  defaults to the field name. The two are separate because a file's column
  names are the file's business: renaming a column in the file changes one
  `:header`, not every call site.

  See `Delimited.Field` for the field options and `Delimited.Type` for the
  types.

  ## Dialect

  `delimited_schema/2` takes a format name, dialect options, or both, and they
  become the schema's defaults:

      delimited_schema :tsv, headers: false do
        field :sku, :string
      end

  Any read or write can override them, so the dialect here should describe the
  file the schema was written for, not the only file it will ever meet. See
  `Delimited.Dialect`.

  ## Introspection

    * `__delimited__(:fields)` returns the `Delimited.Field` structs in
      declaration order.
    * `__delimited__(:dialect)` returns the declared `Delimited.Dialect`.

  Both are public, because generating a blank template, a column list for an
  upload form, or documentation from the schema is the point of declaring it
  once.
  """

  alias Delimited.Dialect
  alias Delimited.Field

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Delimited.Schema,
        only: [delimited_schema: 1, delimited_schema: 2, delimited_schema: 3]
    end
  end

  @doc """
  Declares the columns, and optionally the dialect, of a delimited file.

  Defines a struct with one key per field, defaulting to the field's `:default`.
  """
  defmacro delimited_schema(format \\ :csv, opts \\ [], do: block) do
    quote do
      Module.register_attribute(__MODULE__, :delimited_fields, accumulate: true)

      try do
        import Delimited.Schema, only: [field: 2, field: 3]
        unquote(block)
      after
        :ok
      end

      @delimited_field_list Delimited.Schema.__fields__(__MODULE__, @delimited_fields)
      @delimited_dialect Delimited.Dialect.new!(unquote(format), unquote(opts))

      defstruct Enum.map(@delimited_field_list, &{&1.name, &1.default})

      @typedoc "A row of #{inspect(__MODULE__)}."
      @type t :: %__MODULE__{}

      @doc """
      Returns this schema's declaration. See `Delimited.Schema`.
      """
      @spec __delimited__(:fields) :: [Delimited.Field.t()]
      @spec __delimited__(:dialect) :: Delimited.Dialect.t()
      def __delimited__(:fields), do: @delimited_field_list
      def __delimited__(:dialect), do: @delimited_dialect
    end
  end

  @doc """
  Declares one column.

  The type defaults to `:string`, which is the type of every cell before
  anything is decided about it. See `Delimited.Field` for the options and
  `Delimited.Type` for the types.
  """
  defmacro field(name, type \\ :string, opts \\ []) do
    quote do
      Delimited.Schema.__field__(__MODULE__, unquote(name), unquote(type), unquote(opts))
    end
  end

  @doc false
  @spec __field__(module(), atom(), term(), keyword()) :: :ok
  def __field__(module, name, type, opts) do
    Module.put_attribute(module, :delimited_fields, Field.new!(name, type, opts))
  end

  @doc false
  @spec __fields__(module(), [Field.t()]) :: [Field.t()]
  def __fields__(module, accumulated) do
    fields = Enum.reverse(accumulated)

    if fields == [] do
      raise ArgumentError,
            "#{inspect(module)} declares no fields. A schema with no columns can " <>
              "neither read nor write a row. Declare at least one field."
    end

    check_unique!(module, fields, & &1.name, "field")
    check_unique!(module, fields, & &1.header, "header")
    fields
  end

  defp check_unique!(module, fields, key, label) do
    duplicates =
      fields
      |> Enum.group_by(key)
      |> Enum.filter(fn {_value, group} -> length(group) > 1 end)
      |> Enum.map(fn {value, _group} -> value end)

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)} declares the #{label} #{inspect(hd(duplicates))} more " <>
              "than once. Two fields reading the same column, or two columns with the " <>
              "same name, cannot both be honoured."
    end
  end

  @doc false
  @spec ensure_schema!(module()) :: module()
  def ensure_schema!(module) when is_atom(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :__delimited__, 1) do
      module
    else
      raise ArgumentError,
            "expected a module that calls `use Delimited.Schema` and declares a " <>
              "`delimited_schema` block, got: #{inspect(module)}"
    end
  end

  @doc false
  @spec dialect_for!(module(), keyword() | atom()) :: Dialect.t()
  def dialect_for!(module, opts) do
    module = ensure_schema!(module)

    Dialect.merge!(module.__delimited__(:dialect), opts)
  end
end
