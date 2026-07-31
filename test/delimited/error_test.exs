defmodule Delimited.ErrorTest do
  use ExUnit.Case, async: true

  alias Delimited.Error

  # Every reason, with the attributes its message reads. A reason added without
  # a message clause raises here rather than in front of an operator.
  @errors [
    {:unterminated_quote, [line: 4]},
    {:unescaped_quote, [line: 4, column: 2]},
    {:missing_header_row, []},
    {:missing_header, [field: :hired_on, header: "Hire Date"]},
    {:duplicate_header, [field: :name, header: "name"]},
    {:extra_header, [header: "notes"]},
    {:row_length_mismatch, [line: 4, detail: {6, 2}]},
    {:record_too_short, [line: 4, detail: {38, 9}]},
    {:invalid_encoding, [line: 4, column: 2, field: :account, value: <<49, 195>>]},
    {:value_too_wide, [line: 4, column: 2, field: :account, value: "toolong", detail: {4, 7}]},
    {:cast_failed, [line: 4, column: 3, field: :id, value: "x", detail: "a whole number"]},
    {:required_field_missing, [line: 4, column: 2, field: :name]},
    {:dump_failed, [line: 4, field: :hired_on, value: "today", detail: "a Date"]},
    {:missing_value, [field: :active]},
    {:io_error, [path: "employees.csv", detail: :enoent]}
  ]

  describe "message/1" do
    test "every reason states what happened and what to do about it" do
      for {reason, attributes} <- @errors do
        message = reason |> Error.new(attributes) |> Exception.message()

        assert String.ends_with?(message, "."), "#{reason}: message does not end in a full stop"
        assert String.length(message) > 40, "#{reason}: message says too little"

        assert message =~
                 ~r/\b(Add|Supply|Correct|Repair|Rename|Declare|Close|Write|Check|Keep|Shorten)\b/,
               "#{reason}: message does not state the next action"
      end
    end

    test "reports position from the outside in" do
      error =
        Error.new(:cast_failed,
          path: "employees.csv",
          line: 4,
          column: 3,
          field: :id,
          value: "x",
          detail: "a whole number"
        )

      assert Exception.message(error) =~ "employees.csv, line 4, column 3, field :id: "
    end

    test "reports no position when the failure has none" do
      message = :missing_header_row |> Error.new() |> Exception.message()

      assert String.starts_with?(message, "the input ended")
    end

    test "reads a POSIX reason for an operator" do
      message = Error.new(:io_error, path: "x.csv", detail: :eacces) |> Exception.message()

      assert message =~ "permission denied"
      assert message =~ ":eacces"
    end
  end

  test "is raisable, and keeps its reason" do
    assert_raise Error, fn -> raise Error.new(:missing_header_row) end

    error = %Error{} = catch_error(raise Error.new(:missing_header_row))
    assert error.reason == :missing_header_row
  end
end
