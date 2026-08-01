defmodule Delimited.Embed do
  @moduledoc false

  # Expands an embedded schema into its parent's own fields.
  #
  # An embed is resolved when the parent schema compiles, not when a file is
  # read: the embedded schema's fields are copied into the parent with their
  # headers prefixed, or their positions shifted, and what remains at runtime is
  # an ordinary flat list of fields. Everything already built on that list —
  # header matching, position overlap checks, `Delimited.headers/1` — therefore
  # keeps working without knowing embeds exist.
  #
  # What the flat list cannot express is the shape of the row that comes back,
  # so the parent also keeps a tree. The tree flattens in exactly the order the
  # field list is built, which is what lets the reader hand out values by
  # walking both together, with no index to keep in step.

  alias Delimited.Dialect
  alias Delimited.Error
  alias Delimited.Field

  @typedoc """
  One node of a schema's shape.

  `{:field, field}` is a column. `{:one, ...}` is an embedded schema, and
  `{:many, ...}` is the same schema repeated a declared number of times, its
  copies already materialised with their own headers or positions.
  """
  @type element ::
          {:field, Field.t()}
          | {:one, atom(), module(), boolean(), [element()]}
          | {:many, atom(), module(), boolean(), [[element()]]}

  @options [:prefix, :at, :count, :stride, :required]

  @doc """
  Expands one declared embed into a node of the parent's shape.
  """
  @spec expand!(module(), :one | :many, atom(), module(), keyword(), Dialect.t()) :: element()
  def expand!(parent, kind, name, embedded, opts, %Dialect{} = dialect) do
    check_options!(parent, name, opts)
    check_embeddable!(parent, name, embedded, dialect)

    shape = embedded.__delimited__(:shape)
    required? = Keyword.get(opts, :required, false)

    case kind do
      :one -> {:one, name, embedded, required?, place(parent, name, shape, opts, dialect, 1)}
      :many -> {:many, name, embedded, required?, groups(parent, name, shape, opts, dialect)}
    end
  end

  @doc """
  Returns a shape's fields, in the order the file holds them.
  """
  @spec flatten([element()]) :: [Field.t()]
  def flatten(shape) do
    Enum.flat_map(shape, fn
      {:field, field} -> [field]
      {:one, _name, _module, _required?, children} -> flatten(children)
      {:many, _name, _module, _required?, groups} -> Enum.flat_map(groups, &flatten/1)
    end)
  end

  @doc """
  Builds a row from the values its fields cast to, in the order they were read.

  An embed whose every value is absent is itself absent, recursively, because
  a group of empty columns is how a file says a group is not there. A field's
  `:default` counts as a value, so a default inside an embed keeps that embed
  present.
  """
  @spec build([element()], [term()], module(), pos_integer()) ::
          {:ok, struct()} | {:error, [Error.t()]}
  def build(shape, values, schema, line) do
    {pairs, _rest, errors, _empty?} = assemble(shape, values, line, [])

    case errors do
      [] -> {:ok, struct!(schema, pairs)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp assemble(shape, values, line, errors) do
    Enum.reduce(shape, {[], values, errors, true}, &assemble_one(&1, &2, line))
  end

  defp assemble_one({:field, field}, {pairs, [value | rest], errors, empty?}, _line) do
    {[{field.name, value} | pairs], rest, errors, empty? and is_nil(value)}
  end

  defp assemble_one(
         {:one, name, module, required?, children},
         {pairs, values, errors, empty?},
         line
       ) do
    {value, rest, errors} = embedded(children, module, values, errors, name, required?, line)

    {[{name, value} | pairs], rest, errors, empty? and is_nil(value)}
  end

  defp assemble_one(
         {:many, name, module, required?, groups},
         {pairs, values, errors, empty?},
         line
       ) do
    {copies, rest, errors} =
      Enum.reduce(groups, {[], values, errors}, fn children, {copies, unread, errors} ->
        {value, rest, errors} = embedded(children, module, unread, errors, name, required?, line)

        {[value | copies], rest, errors}
      end)

    copies = Enum.reverse(copies)

    {[{name, copies} | pairs], rest, errors, empty? and Enum.all?(copies, &is_nil/1)}
  end

  defp embedded(children, module, values, errors, name, required?, line) do
    {pairs, rest, errors, empty?} = assemble(children, values, line, errors)
    value = if empty?, do: nil, else: struct!(module, pairs)

    {value, rest, required_error(value, errors, name, required?, line)}
  end

  defp required_error(nil, errors, name, true, line),
    do: [Error.new(:required_field_missing, field: name, line: line) | errors]

  defp required_error(_value, errors, _name, _required?, _line), do: errors

  @doc """
  Takes the values a row holds, in the order the file wants them.

  An embed that is `nil` writes its columns blank, which is the counterpart of
  reading a blank group as `nil`.
  """
  @spec values([element()], term()) :: {:ok, [{Field.t(), term()}]} | {:error, Error.t()}
  def values(shape, row) do
    case collect(shape, row, []) do
      %Error{} = error -> {:error, error}
      pairs -> {:ok, Enum.reverse(pairs)}
    end
  end

  defp collect(shape, row, pairs) do
    Enum.reduce_while(shape, pairs, fn element, pairs ->
      case take(element, row, pairs) do
        %Error{} = error -> {:halt, error}
        pairs -> {:cont, pairs}
      end
    end)
  end

  defp take({:field, field}, row, pairs) do
    case fetch(row, field.name) do
      {:ok, value} -> [{field, value} | pairs]
      :error -> Error.new(:missing_value, field: field.name)
    end
  end

  defp take({:one, name, _module, required?, children}, row, pairs) do
    case fetch(row, name) do
      {:ok, nil} when required? -> Error.new(:required_field_missing, field: name)
      {:ok, nil} -> collect(children, :absent, pairs)
      {:ok, embedded} -> collect(children, embedded, pairs)
      :error -> Error.new(:missing_value, field: name)
    end
  end

  defp take({:many, name, _module, required?, groups}, row, pairs) do
    with {:ok, copies} <- fetch(row, name),
         {:ok, copies} <- fit(copies, length(groups), name) do
      groups
      |> Enum.zip(copies)
      |> Enum.reduce_while(pairs, &take_copy(&1, &2, name, required?))
    else
      :error -> Error.new(:missing_value, field: name)
      %Error{} = error -> error
    end
  end

  defp take_copy({_children, nil}, _pairs, name, true) do
    {:halt, Error.new(:required_field_missing, field: name)}
  end

  defp take_copy({children, copy}, pairs, _name, _required?) do
    case collect(children, copy || :absent, pairs) do
      %Error{} = error -> {:halt, error}
      pairs -> {:cont, pairs}
    end
  end

  # A row may hold fewer copies than the file has room for, and the rest are
  # written blank. It may not hold more: there would be nowhere to put them.
  defp fit(copies, count, _name) when is_list(copies) and length(copies) <= count,
    do: {:ok, copies ++ List.duplicate(nil, count - length(copies))}

  defp fit(copies, count, name) when is_list(copies),
    do:
      Error.new(:dump_failed,
        field: name,
        value: copies,
        detail: "at most #{count} of them, which is how many the schema declares"
      )

  defp fit(other, count, name),
    do:
      Error.new(:dump_failed,
        field: name,
        value: other,
        detail: "a list of at most #{count} rows"
      )

  defp fetch(:absent, _name), do: {:ok, nil}
  defp fetch(row, name) when is_map(row), do: Map.fetch(row, name)
  defp fetch(_row, _name), do: :error

  defp groups(parent, name, shape, opts, dialect) do
    count = count!(parent, name, opts)
    stride = stride!(parent, name, shape, opts, dialect)
    origin = Keyword.get(opts, :at, 1)

    check_numbered_prefix!(parent, name, opts, count, dialect)

    Enum.map(1..count, fn index ->
      place(parent, name, shape, put_origin(opts, origin, stride, index), dialect, index)
    end)
  end

  defp put_origin(opts, origin, stride, index),
    do: Keyword.put(opts, :at, origin + (index - 1) * stride)

  # Under the delimited layout an embed is told apart by a prefix on its
  # headers; under the fixed layout there are no headers to prefix, so it is
  # told apart by where its bytes start.
  defp place(parent, name, shape, opts, %{layout: :fixed} = dialect, _index) do
    offset = Keyword.get(opts, :at, 1) - 1

    if offset < 0 do
      raise ArgumentError,
            "the :at of embed #{inspect(name)} in #{inspect(parent)} must be a positive " <>
              "starting position, counted the way a field's is."
    end

    map_fields(shape, dialect, &shift(&1, offset))
  end

  defp place(parent, name, shape, opts, dialect, index) do
    prefix = prefix!(parent, name, opts, index)

    map_fields(shape, dialect, &prepend(&1, prefix))
  end

  defp map_fields(shape, dialect, function) do
    Enum.map(shape, fn
      {:field, field} ->
        {:field, function.(field)}

      {:one, name, module, required?, children} ->
        {:one, name, module, required?, map_fields(children, dialect, function)}

      {:many, name, module, required?, groups} ->
        {:many, name, module, required?, Enum.map(groups, &map_fields(&1, dialect, function))}
    end)
  end

  defp shift(%Field{at: {offset, length}} = field, by), do: %{field | at: {offset + by, length}}

  defp prepend(%Field{header: header} = field, prefix), do: %{field | header: prefix <> header}

  # A repeated group needs a different prefix per copy, or its columns would all
  # claim the same name.
  defp prefix!(_parent, _name, opts, index) do
    opts |> Keyword.get(:prefix, "") |> String.replace("{n}", Integer.to_string(index))
  end

  # Every copy needs a header of its own, so a repeated group's prefix has to
  # say which copy it is.
  defp check_numbered_prefix!(_parent, _name, _opts, 1, _dialect), do: :ok
  defp check_numbered_prefix!(_parent, _name, _opts, _count, %{layout: :fixed}), do: :ok

  defp check_numbered_prefix!(parent, name, opts, _count, _dialect) do
    prefix = Keyword.get(opts, :prefix, "")

    if String.contains?(prefix, "{n}") do
      :ok
    else
      raise ArgumentError,
            "the :prefix #{inspect(prefix)} of embeds_many #{inspect(name)} in " <>
              "#{inspect(parent)} does not hold {n}, so every copy would claim the same " <>
              "columns. Write it as \"item_{n}_\", where {n} becomes the copy's number."
    end
  end

  defp count!(parent, name, opts) do
    case Keyword.fetch(opts, :count) do
      {:ok, count} when is_integer(count) and count > 0 ->
        count

      _other ->
        raise ArgumentError,
              "embeds_many #{inspect(name)} in #{inspect(parent)} needs a positive :count. " <>
                "A row holds a fixed number of columns, so a repeated group has to say " <>
                "how many times it repeats."
    end
  end

  # The stride defaults to the width the embedded schema declares, which is what
  # a file repeating a block back to back does. A file that leaves a gap between
  # copies says so.
  defp stride!(_parent, _name, _shape, _opts, %{layout: :delimited}), do: 0

  defp stride!(parent, name, shape, opts, _dialect) do
    case Keyword.get(opts, :stride, width(shape)) do
      stride when is_integer(stride) and stride > 0 ->
        stride

      other ->
        raise ArgumentError,
              "the :stride of embeds_many #{inspect(name)} in #{inspect(parent)} must be a " <>
                "positive number of bytes, got: #{inspect(other)}"
    end
  end

  defp width(shape) do
    shape |> flatten() |> Enum.map(&Field.ends_at/1) |> Enum.max()
  end

  defp check_options!(parent, name, opts) do
    case Enum.reject(Keyword.keys(opts), &(&1 in @options)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option#{if length(unknown) > 1, do: "s"} " <>
                "#{Enum.map_join(unknown, ", ", &inspect/1)} on embed #{inspect(name)} in " <>
                "#{inspect(parent)}. The options are #{inspect(@options)}."
    end
  end

  defp check_embeddable!(parent, name, embedded, dialect) do
    Code.ensure_compiled!(embedded)

    if not function_exported?(embedded, :__delimited__, 1) do
      raise ArgumentError,
            "#{inspect(embedded)}, embedded as #{inspect(name)} in #{inspect(parent)}, is not " <>
              "a schema. Declare it with `use Delimited.Schema`."
    end

    check_layout!(parent, name, embedded, dialect)
  end

  defp check_layout!(parent, name, embedded, dialect) do
    embedded_layout = embedded.__delimited__(:dialect).layout

    if embedded_layout != dialect.layout do
      raise ArgumentError,
            "#{inspect(embedded)} is declared #{inspect(embedded_layout)} and is embedded as " <>
              "#{inspect(name)} in #{inspect(parent)}, which is #{inspect(dialect.layout)}. " <>
              "An embedded schema supplies the positions or the headers its parent uses, so " <>
              "the two must agree on which of those a field has."
    end
  end
end
