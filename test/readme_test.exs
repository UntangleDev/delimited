defmodule Delimited.ReadmeTest do
  @moduledoc """
  Runs the README's examples.

  The README is the first thing a reader copies. These tests exist so that it
  cannot describe a library other than the one that is here.
  """

  use ExUnit.Case, async: true

  defmodule Employee do
    @moduledoc false

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

  defmodule Pence do
    @moduledoc false

    @behaviour Delimited.Type

    @impl true
    def cast("£" <> amount, _opts) do
      case Float.parse(amount) do
        {pounds, ""} -> {:ok, round(pounds * 100)}
        _other -> {:error, "an amount in pounds"}
      end
    end

    def cast(_text, _opts), do: {:error, "an amount in pounds"}

    @impl true
    def dump(pence, _opts) when is_integer(pence) do
      penny = pence |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

      {:ok, ["£", Integer.to_string(div(pence, 100)), ".", penny]}
    end

    def dump(_other, _opts), do: {:error, "an amount in pounds"}
  end

  defmodule Salaried do
    @moduledoc false

    use Delimited.Schema

    delimited_schema do
      field :name, :string
      field :salary, Pence
    end
  end

  @csv """
  Employee ID,name,department,Hire Date,salary,active
  1,"Lovelace, Ada",ENG,1843-01-01,1200.50,true
  """

  @tag :tmp_dir
  test "the opening example reads what it says it does", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "employees.csv")
    File.write!(path, @csv)

    assert {:ok, employees} = Delimited.read(Employee, path)

    assert employees == [
             %Employee{
               id: 1,
               name: "Lovelace, Ada",
               department: :engineering,
               hired_on: ~D[1843-01-01],
               salary: Decimal.new("1200.50"),
               active: true
             }
           ]

    tsv = Path.join(tmp_dir, "employees.tsv")

    assert Delimited.write(Employee, tsv, employees, :tsv) == :ok
    assert File.read!(tsv) =~ "1\tLovelace, Ada\tENG\t1843-01-01\t1200.50\ttrue\n"
  end

  test "the custom type example reads and writes an amount in pounds" do
    csv = "name,salary\nAda,£1200.05\n"

    assert {:ok, [%Salaried{salary: 120_005}] = rows} = Delimited.decode(Salaried, csv)
    assert Salaried |> Delimited.encode!(rows) |> Enum.to_list() |> IO.iodata_to_binary() == csv
  end

  test "the error message is the one the README shows" do
    csv = "Employee ID,name,department,Hire Date,salary,active\n1,A,ENG,01/03/2024,,true\n"

    assert {:error, [error]} = Delimited.decode(Employee, csv)

    expected =
      "line 2, column 4, field :hired_on: cannot read \"01/03/2024\" as a date in " <>
        "ISO 8601 form (YYYY-MM-DD). Correct the value, or declare the field with " <>
        "a type that accepts it."

    assert Exception.message(error) == expected
  end

  test "a column the schema declares and the file does not hold is an error" do
    assert {:error, [%Delimited.Error{reason: :missing_header} | _rest]} =
             Delimited.decode(Employee, "Employee ID,name\n1,A\n")
  end

  test "a column the file holds and the schema does not declare is ignored" do
    csv = "Employee ID,name,department,Hire Date,salary,active,notes\n1,A,ENG,,,,x\n"

    assert {:ok, [%Employee{name: "A"}]} = Delimited.decode(Employee, csv)
  end
end
