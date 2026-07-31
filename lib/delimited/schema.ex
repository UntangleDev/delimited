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

  ## Repeated groups of columns

  A file often carries the same group of columns more than once. Declare the
  group once and embed it:

      defmodule Address do
        use Delimited.Schema

        delimited_schema do
          field :street, :string
          field :city, :string
        end
      end

      defmodule Order do
        use Delimited.Schema

        delimited_schema do
          field :id, :integer
          embeds_one :billing, Address, prefix: "billing_"
          embeds_one :shipping, Address, prefix: "shipping_"
          embeds_many :lines, LineItem, count: 2, prefix: "item_{n}_"
        end
      end

  That reads `billing_street`, `shipping_street`, `item_1_sku`, `item_2_sku`
  and the rest into `%Order{billing: %Address{}, lines: [%LineItem{}, ...]}`.
  Declaring the group once is the point: two copies of a column list cannot
  drift apart, and `shipping_postcode` cannot end up reading the billing one.

  An embed is resolved when the schema compiles, so what the reader works with
  is still a flat list of columns. See `embeds_one/3` and `embeds_many/3`.

  A group whose every column is empty reads as `nil`, and `nil` writes its
  columns back empty, which is the same rule the fixed layout uses for a blank
  field. One column filled makes the group present.

  ## Introspection

    * `__delimited__(:fields)` returns the `Delimited.Field` structs in the
      order the file holds them, with any embedded schema's fields expanded in
      place.
    * `__delimited__(:dialect)` returns the declared `Delimited.Dialect`.

  Both are public, because generating a blank template, a column list for an
  upload form, or documentation from the schema is the point of declaring it
  once. `__delimited__(:shape)` also exists, and holds the nesting that the
  flat list cannot express; it is internal and may change.
  """

  alias Delimited.Dialect
  alias Delimited.Embed
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
      Module.register_attribute(__MODULE__, :delimited_declarations, accumulate: true)

      try do
        import Delimited.Schema,
          only: [field: 2, field: 3, embeds_one: 2, embeds_one: 3, embeds_many: 3]

        unquote(block)
      after
        :ok
      end

      # The dialect is built first because the layout decides which field
      # options are required and which are meaningless, and how an embed is
      # told apart from its siblings.
      @delimited_dialect Delimited.Dialect.new!(unquote(format), unquote(opts))
      @delimited_shape Delimited.Schema.__shape__(
                         __MODULE__,
                         @delimited_declarations,
                         @delimited_dialect
                       )
      @delimited_field_list Delimited.Schema.__fields__(
                              __MODULE__,
                              @delimited_shape,
                              @delimited_dialect
                            )

      defstruct Delimited.Schema.__struct_keys__(@delimited_shape)

      @typedoc "A row of #{inspect(__MODULE__)}."
      @type t :: %__MODULE__{}

      @doc """
      Returns this schema's declaration. See `Delimited.Schema`.
      """
      @spec __delimited__(:fields) :: [Delimited.Field.t()]
      @spec __delimited__(:dialect) :: Delimited.Dialect.t()
      @spec __delimited__(:shape) :: [Delimited.Embed.element()]
      def __delimited__(:fields), do: @delimited_field_list
      def __delimited__(:dialect), do: @delimited_dialect
      def __delimited__(:shape), do: @delimited_shape
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

  @doc """
  Embeds another schema's columns in this one.

      embeds_one :billing, Address, prefix: "billing_"

  Reads `billing_street` and `billing_city` into `%Order{billing: %Address{}}`.
  Under the fixed layout there are no headers to prefix, so the embed says where
  its bytes start instead, and the embedded schema's own positions are counted
  from there:

      embeds_one :payer, Party, at: 2

  An embed whose every column is empty reads as `nil`, which is what an absent
  group means. `required: true` makes that an error instead.
  """
  defmacro embeds_one(name, schema, opts \\ []) do
    quote do
      Delimited.Schema.__embed__(
        __MODULE__,
        :one,
        unquote(name),
        unquote(schema),
        unquote(opts)
      )
    end
  end

  @doc """
  Embeds another schema's columns a declared number of times.

      embeds_many :lines, LineItem, count: 3, prefix: "item_{n}_"

  Reads `item_1_sku`, `item_2_sku`, and `item_3_sku` into
  `%Order{lines: [%LineItem{}, %LineItem{}, %LineItem{}]}`. `{n}` becomes each
  copy's number, and is required, because otherwise every copy would claim the
  same columns.

  A row holds a fixed number of columns, so a repeated group has to say how many
  times it repeats. Under the fixed layout the copies follow one another by the
  embedded schema's own width, or by a declared `:stride` where the file leaves
  a gap between them.
  """
  defmacro embeds_many(name, schema, opts) do
    quote do
      Delimited.Schema.__embed__(
        __MODULE__,
        :many,
        unquote(name),
        unquote(schema),
        unquote(opts)
      )
    end
  end

  @doc false
  @spec __field__(module(), atom(), term(), keyword()) :: :ok
  def __field__(module, name, type, opts) do
    Module.put_attribute(module, :delimited_declarations, {:field, Field.new!(name, type, opts)})
  end

  @doc false
  @spec __embed__(module(), :one | :many, atom(), module(), keyword()) :: :ok
  def __embed__(module, kind, name, schema, opts) when is_atom(name) and is_list(opts) do
    Module.put_attribute(module, :delimited_declarations, {:embed, kind, name, schema, opts})
  end

  @doc false
  @spec __shape__(module(), [tuple()], Dialect.t()) :: [Embed.element()]
  def __shape__(module, declarations, %Dialect{} = dialect) do
    declarations
    |> Enum.reverse()
    |> Enum.map(fn
      {:field, field} ->
        {:field, field}

      {:embed, kind, name, schema, opts} ->
        Embed.expand!(module, kind, name, schema, opts, dialect)
    end)
  end

  @doc false
  @spec __struct_keys__([Embed.element()]) :: keyword()
  def __struct_keys__(shape) do
    Enum.map(shape, fn
      {:field, field} -> {field.name, field.default}
      {:one, name, _schema, _required?, _children} -> {name, nil}
      {:many, name, _schema, _required?, _groups} -> {name, []}
    end)
  end

  @doc false
  @spec __fields__(module(), [Embed.element()], Dialect.t()) :: [Field.t()]
  def __fields__(module, shape, %Dialect{} = dialect) do
    fields = Embed.flatten(shape)

    if fields == [] do
      raise ArgumentError,
            "#{inspect(module)} declares no fields. A schema with no columns can " <>
              "neither read nor write a row. Declare at least one field."
    end

    check_names!(module, shape)
    check_headers!(module, fields, dialect)
    check_layout!(module, fields, dialect)
    fields
  end

  # Names have to be unique among the keys of one struct, not across the file:
  # two embedded copies of the same schema both hold a :street, and they are
  # different structs. An embedded schema checked its own names when it
  # compiled, so only this level is checked here.
  defp check_names!(module, shape) do
    names =
      Enum.map(shape, fn
        {:field, field} -> field.name
        {:one, name, _schema, _required?, _children} -> name
        {:many, name, _schema, _required?, _groups} -> name
      end)

    check_unique!(module, names, & &1, "name")
  end

  # Under the fixed layout a column is identified by where it starts, and two
  # embedded copies of one schema necessarily repeat its headers. Positions are
  # checked for overlap instead.
  defp check_headers!(_module, _fields, %{layout: :fixed}), do: :ok

  defp check_headers!(module, fields, _dialect) do
    check_unique!(module, fields, & &1.header, "header")
  end

  defp check_layout!(module, fields, %{layout: :fixed} = dialect) do
    Enum.each(fields, fn field ->
      if is_nil(field.at) do
        raise ArgumentError,
              "field #{inspect(field.name)} of #{inspect(module)} declares no position. " <>
                "Under `layout: :fixed` a field is a range of bytes, so every field " <>
                "needs one, written as the file's specification writes it: `at: 8..15`."
      end
    end)

    check_overlaps!(module, fields)
    check_record_length!(module, fields, dialect)
  end

  defp check_layout!(module, fields, _dialect) do
    Enum.each(fields, fn field ->
      case Enum.find([:at, :align, :pad], &(not is_nil(Map.fetch!(field, &1)))) do
        nil ->
          :ok

        option ->
          raise ArgumentError,
                "field #{inspect(field.name)} of #{inspect(module)} declares " <>
                  "#{inspect(option)}, which only the fixed-width layout can honour. " <>
                  "Declare the schema with `:fixed`, or drop the option."
      end
    end)
  end

  defp check_overlaps!(module, fields) do
    fields
    |> Enum.sort_by(& &1.at)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [earlier, later] ->
      if Field.ends_at(earlier) > elem(later.at, 0) do
        raise ArgumentError,
              "fields #{inspect(earlier.name)} at #{inspect(Field.declared_at(earlier))} and " <>
                "#{inspect(later.name)} at #{inspect(Field.declared_at(later))} in " <>
                "#{inspect(module)} cover some of the same bytes. Two fields cannot both " <>
                "own a position; check them against the file's specification."
      end
    end)
  end

  defp check_record_length!(_module, _fields, %{record_length: :line}), do: :ok

  defp check_record_length!(module, fields, %{record_length: length}) do
    last = fields |> Enum.map(&Field.ends_at/1) |> Enum.max()

    if last > length do
      overrun = Enum.max_by(fields, &Field.ends_at/1)

      raise ArgumentError,
            "field #{inspect(overrun.name)} of #{inspect(module)} ends at position #{last}, " <>
              "beyond the declared `record_length: #{length}`. Every record would be too " <>
              "short to hold it. Correct the position or the record length."
    end
  end

  @explanations %{
    "name" =>
      "A field's or an embed's name is a key of this schema's struct, so two of " <>
        "them cannot share one. Two embeds of the same schema may each hold a " <>
        "field of that name, because they are different structs.",
    "header" =>
      "Two fields reading the same column, or two columns with the same name, " <>
        "cannot both be honoured."
  }

  defp check_unique!(module, values, key, label) do
    duplicates =
      values
      |> Enum.group_by(key)
      |> Enum.filter(fn {_value, group} -> length(group) > 1 end)
      |> Enum.map(fn {value, _group} -> value end)

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)} declares the #{label} #{inspect(hd(duplicates))} more " <>
              "than once. #{Map.fetch!(@explanations, label)}"
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
