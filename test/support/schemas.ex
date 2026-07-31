defmodule Delimited.Test.Money do
  @moduledoc false
  # A custom type, used to prove that the behaviour is enough to read and write
  # something the built-in types refuse: a value with a currency symbol.

  @behaviour Delimited.Type

  @impl true
  def cast(text, opts) do
    symbol = Keyword.get(opts, :symbol, "£")

    case String.split(text, symbol, parts: 2) do
      ["", amount] -> parse(amount)
      _other -> {:error, "an amount in #{symbol}"}
    end
  end

  @impl true
  def dump(pence, opts) when is_integer(pence) do
    symbol = Keyword.get(opts, :symbol, "£")
    {:ok, [symbol, Integer.to_string(div(pence, 100)), ".", pad(rem(pence, 100))]}
  end

  def dump(_other, opts) do
    {:error, "an amount in #{Keyword.get(opts, :symbol, "£")}"}
  end

  defp parse(amount) do
    case Float.parse(amount) do
      {value, ""} -> {:ok, round(value * 100)}
      _other -> {:error, "an amount"}
    end
  end

  defp pad(pence), do: String.pad_leading(Integer.to_string(pence), 2, "0")
end

defmodule Delimited.Test.Employee do
  @moduledoc false

  use Delimited.Schema

  delimited_schema do
    field :id, :integer, header: "Employee ID"
    field :name, :string, required: true
    field :department, {:enum, [engineering: "ENG", sales: "SLS"]}
    field :hired_on, :date, header: "Hire Date"
    field :salary, Delimited.Test.Money
    field :active, :boolean, default: true
  end
end

defmodule Delimited.Test.Product do
  @moduledoc false

  use Delimited.Schema

  delimited_schema :tsv, headers: false do
    field :sku, :string
    field :price, :decimal
  end
end

defmodule Delimited.Test.Reading do
  @moduledoc false
  # One field of each built-in type, for exercising casting and dumping through
  # the public API rather than through Delimited.Type alone.

  use Delimited.Schema

  delimited_schema do
    field :string, :string
    field :integer, :integer
    field :float, :float
    field :boolean, :boolean
    field :date, :date
    field :time, :time
    field :naive_datetime, :naive_datetime
    field :utc_datetime, :utc_datetime
    field :decimal, :decimal
  end
end
