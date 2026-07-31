defmodule DelimitedTest do
  use ExUnit.Case, async: true

  alias Delimited.Error
  alias Delimited.Test.Employee
  alias Delimited.Test.Product

  doctest Delimited

  @csv """
  Employee ID,name,department,Hire Date,salary,active
  1,"Lovelace, Ada",ENG,1843-01-01,£1200.50,true
  2,Grace Hopper,SLS,1944-07-02,,false
  """

  describe "decode/3" do
    test "reads every declared column" do
      assert {:ok, [ada, grace]} = Delimited.decode(Employee, @csv)

      assert ada == %Employee{
               id: 1,
               name: "Lovelace, Ada",
               department: :engineering,
               hired_on: ~D[1843-01-01],
               salary: 120_050,
               active: true
             }

      assert grace.department == :sales
      assert grace.active == false
    end

    test "reads an empty cell as the field's default" do
      assert {:ok, [_ada, grace]} = Delimited.decode(Employee, @csv)
      assert grace.salary == nil
    end

    test "reads slices as well as a binary" do
      slices = for <<slice::binary-7 <- @csv>>, do: slice
      remainder = binary_part(@csv, div(byte_size(@csv), 7) * 7, rem(byte_size(@csv), 7))

      assert Delimited.decode(Employee, slices ++ [remainder]) == Delimited.decode(Employee, @csv)
    end

    test "ignores a column no field declares" do
      csv =
        "Employee ID,name,department,Hire Date,salary,active,notes\n" <> "1,A,ENG,,,,ignored\n"

      assert {:ok, [employee]} = Delimited.decode(Employee, csv)
      assert employee.name == "A"
    end

    test "reports a column no field declares when told to" do
      csv = "Employee ID,name,department,Hire Date,salary,active,notes\n1,A,ENG,,,,x\n"

      assert {:error, [%Error{reason: :extra_header, header: "notes"}]} =
               Delimited.decode(Employee, csv, on_extra_header: :error)
    end

    test "reports a declared column the file does not hold" do
      assert {:error, errors} = Delimited.decode(Employee, "Employee ID,name\n1,A\n")

      assert Enum.map(errors, & &1.field) == [:department, :hired_on, :salary, :active]
      assert Enum.all?(errors, &(&1.reason == :missing_header))
    end

    test "leaves a missing column at its default when told to" do
      assert {:ok, [employee]} =
               Delimited.decode(Employee, "Employee ID,name\n1,A\n", on_missing_header: :ignore)

      assert employee.department == nil
      assert employee.active == true
    end

    test "reports an ambiguous column" do
      csv = "Employee ID,name,department,Hire Date,salary,active,name\n1,A,ENG,,,,B\n"

      assert {:error, [%Error{reason: :duplicate_header, header: "name", field: :name}]} =
               Delimited.decode(Employee, csv)
    end

    test "reports an input with no header row" do
      assert {:error, [%Error{reason: :missing_header_row}]} = Delimited.decode(Employee, "")
    end

    test "reads no rows from a file holding only a header row" do
      assert {:ok, []} =
               Delimited.decode(Employee, "Employee ID,name,department,Hire Date,salary,active\n")
    end

    test "reports a row of the wrong length" do
      csv = "Employee ID,name,department,Hire Date,salary,active\n1,A\n"

      assert {:error, [%Error{reason: :row_length_mismatch, line: 2} = error]} =
               Delimited.decode(Employee, csv)

      assert Exception.message(error) =~ "the row holds 2 cells where 6 are expected"
    end

    test "reports an unreadable cell without discarding the rows around it" do
      csv = @csv <> "3,C,ENG,not-a-date,,true\n4,D,ENG,2024-01-01,,true\n"

      assert {:error, [error]} = Delimited.decode(Employee, csv)

      assert %Error{
               reason: :cast_failed,
               field: :hired_on,
               line: 4,
               column: 4,
               value: "not-a-date",
               schema: Employee
             } = error
    end

    test "reports a required field that has no value" do
      csv = "Employee ID,name,department,Hire Date,salary,active\n1,,ENG,,,\n"

      assert {:error, [%Error{reason: :required_field_missing, field: :name, line: 2}]} =
               Delimited.decode(Employee, csv)
    end

    test "reads columns by position when the file has no header row" do
      assert {:ok, [%Product{sku: "A-1", price: price}]} =
               Delimited.decode(Product, "A-1\t9.99\n")

      assert Decimal.equal?(price, Decimal.new("9.99"))
    end

    test "applies call-site options over the schema's dialect" do
      assert {:ok, [%Product{sku: "A-1"}]} =
               Delimited.decode(Product, "A-1;9.99\n", delimiter: ";")
    end

    test "skips rows before the header row" do
      csv =
        "Quarterly report\n\nEmployee ID,name,department,Hire Date,salary,active\n1,A,ENG,,,\n"

      assert {:ok, [%Employee{name: "A"}]} = Delimited.decode(Employee, csv, skip_rows: 1)
    end

    test "trims cells when told to" do
      csv = "Employee ID,name,department,Hire Date,salary,active\n  1  ,  A  ,ENG,,,\n"

      assert {:error, [%Error{reason: :cast_failed}]} = Delimited.decode(Employee, csv)
      assert {:ok, [%Employee{id: 1, name: "A"}]} = Delimited.decode(Employee, csv, trim: true)
    end

    test "reads its own null strings" do
      csv = "Employee ID,name,department,Hire Date,salary,active\nN/A,A,ENG,,,\n"

      assert {:ok, [%Employee{id: nil}]} = Delimited.decode(Employee, csv, null: ["", "N/A"])
    end

    test "stops at a parse error but keeps the rows before it" do
      assert {:error, [%Error{reason: :unescaped_quote, line: 4, column: 2}]} =
               Delimited.decode(Employee, @csv <> ~s(3,"C"x,ENG,,,\n))
    end
  end

  describe "decode!/3" do
    test "returns the rows" do
      assert [%Employee{}, %Employee{}] = Delimited.decode!(Employee, @csv)
    end

    test "raises the first error" do
      assert_raise Error, ~r/line 2, column 1, field :id/, fn ->
        Delimited.decode!(
          Employee,
          "Employee ID,name,department,Hire Date,salary,active\nx,A,ENG,,,\n"
        )
      end
    end
  end

  describe "encode!/3" do
    test "writes the header row and every field" do
      assert encode(Employee, Delimited.decode!(Employee, @csv)) == @csv
    end

    test "writes nil as an empty cell" do
      assert encode(Employee, [%Employee{name: "A"}]) =~ "\n,A,,,,true\n"
    end

    test "writes no header row when the schema declares none" do
      assert encode(Product, [%Product{sku: "A-1", price: Decimal.new("9.99")}]) == "A-1\t9.99\n"
    end

    test "writes a plain map holding every field" do
      row = %{id: 1, name: "A", department: nil, hired_on: nil, salary: nil, active: nil}

      assert encode(Employee, [row]) =~ "\n1,A,,,,\n"
    end

    test "raises for a row that does not hold a field" do
      assert_raise Error, ~r/field :active: the row holds no key for this field/, fn ->
        encode(Employee, [%{id: 1, name: "A", department: nil, hired_on: nil, salary: nil}])
      end
    end

    test "raises for a value that does not match its type" do
      assert_raise Error, ~r/line 2, field :hired_on: cannot write "today"/, fn ->
        encode(Employee, [%Employee{name: "A", hired_on: "today"}])
      end
    end

    test "raises for a row that is not a map" do
      assert_raise Error, ~r/struct or a map with the same keys/, fn ->
        encode(Employee, [[id: 1]])
      end
    end

    test "writes a byte order mark when told to" do
      assert <<0xEF, 0xBB, 0xBF>> <> "sku" <> _rest =
               encode(Product, [], headers: true, bom: true)
    end

    test "is lazy" do
      rows = Stream.map([1, 2], fn id -> %Employee{id: id, name: "A"} end)

      assert Employee |> Delimited.encode!(rows) |> Enum.count() == 3
    end
  end

  describe "a round trip" do
    test "preserves every value" do
      rows = Delimited.decode!(Employee, @csv)

      assert Delimited.decode!(Employee, encode(Employee, rows)) == rows
    end

    test "preserves values needing quotes" do
      row = %Employee{id: 1, name: ~s(a,b"c\nd\r\ne), active: false}

      assert Delimited.decode!(Employee, encode(Employee, [row])) == [row]
    end
  end

  describe "read/3 and write/4" do
    @describetag :tmp_dir

    test "write then read returns the same rows", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      rows = Delimited.decode!(Employee, @csv)

      assert Delimited.write(Employee, path, rows) == :ok
      assert Delimited.read(Employee, path) == {:ok, rows}
      assert File.read!(path) == @csv
    end

    test "reads a file in slices", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      File.write!(path, @csv)

      assert {:ok, rows} = Delimited.read(Employee, path, chunk_size: 1)
      assert rows == Delimited.decode!(Employee, @csv)
    end

    test "puts the path on every error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      File.write!(path, "Employee ID,name,department,Hire Date,salary,active\nx,A,ENG,,,\n")

      assert {:error, [%Error{path: ^path} = error]} = Delimited.read(Employee, path)
      assert Exception.message(error) =~ path
    end

    test "reports a file that cannot be opened", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.csv")

      assert {:error, [%Error{reason: :io_error, detail: :enoent, path: ^path} = error]} =
               Delimited.read(Employee, path)

      assert Exception.message(error) =~ "no such file or directory"
    end

    test "reports a file that cannot be written", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "absent", "employees.csv"])

      assert {:error, %Error{reason: :io_error, detail: :enoent}} =
               Delimited.write(Employee, path, [])
    end

    test "read! raises the first error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.csv")

      assert_raise Error, ~r/no such file or directory/, fn -> Delimited.read!(Employee, path) end
    end

    test "write! raises", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "absent", "employees.csv"])

      assert_raise Error, ~r/cannot open the file/, fn ->
        Delimited.write!(Employee, path, [])
      end
    end

    test "write leaves the rows before a failure on disk", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      rows = [%Employee{id: 1, name: "A"}, %Employee{id: 2, name: "B", hired_on: "today"}]

      assert {:error, %Error{reason: :dump_failed, line: 3}} =
               Delimited.write(Employee, path, rows)

      assert File.read!(path) =~ "\n1,A,,,,true\n"
    end

    test "takes a format name", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.tsv")

      assert Delimited.write(Employee, path, [%Employee{id: 1, name: "A"}], :tsv) == :ok
      assert File.read!(path) =~ "1\tA\t\t\t\ttrue\n"
    end
  end

  describe "stream/3" do
    @describetag :tmp_dir

    test "emits a result per row", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      File.write!(path, @csv <> "3,C,ENG,not-a-date,,true\n4,D,ENG,2024-01-01,,true\n")

      results = Employee |> Delimited.stream(path) |> Enum.to_list()

      assert [{:ok, _ada}, {:ok, _grace}, {:error, error}, {:ok, _d}] = results
      assert %Error{reason: :cast_failed, line: 4, path: ^path} = error
    end

    test "reads a stream of slices" do
      results = Employee |> Delimited.stream([@csv]) |> Enum.to_list()

      assert [{:ok, _ada}, {:ok, _grace}] = results
    end

    test "does not read the whole file to produce the first row", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "employees.csv")
      File.write!(path, @csv)

      assert [{:ok, %Employee{id: 1}}] =
               Employee |> Delimited.stream(path, chunk_size: 8) |> Enum.take(1)
    end

    test "raises for a file it cannot open", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.csv")

      assert_raise File.Error, fn ->
        Employee |> Delimited.stream(path) |> Enum.to_list()
      end
    end
  end

  @types_header "string,integer,float,boolean,date,time,naive_datetime,utc_datetime,decimal\n"
  @types_row "a,1,1.5,true,2024-02-29,09:30:00,2024-02-29T09:30:00,2024-03-01T12:00:00Z,1200.50\n"

  describe "the built-in types" do
    alias Delimited.Test.Reading

    test "read one value of each" do
      assert {:ok, [row]} = Delimited.decode(Reading, @types_header <> @types_row)

      assert row == %Reading{
               string: "a",
               integer: 1,
               float: 1.5,
               boolean: true,
               date: ~D[2024-02-29],
               time: ~T[09:30:00],
               naive_datetime: ~N[2024-02-29 09:30:00],
               utc_datetime: ~U[2024-03-01 12:00:00Z],
               decimal: Decimal.new("1200.50")
             }
    end

    test "write back what they read" do
      rows = Delimited.decode!(Reading, @types_header <> @types_row)

      assert encode(Reading, rows) == @types_header <> @types_row
    end

    test "read an empty cell of each as nil" do
      assert {:ok, [row]} = Delimited.decode(Reading, @types_header <> ",,,,,,,,\n")

      assert row == %Reading{}
    end
  end

  describe "headers/1" do
    test "returns the columns a file would have" do
      assert Delimited.headers(Employee) ==
               ["Employee ID", "name", "department", "Hire Date", "salary", "active"]
    end
  end

  defp encode(schema, rows, opts \\ []) do
    schema |> Delimited.encode!(rows, opts) |> Enum.to_list() |> IO.iodata_to_binary()
  end
end
