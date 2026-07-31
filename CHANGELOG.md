# Changelog

This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

## 0.2.0

### Breaking

- `:format`, `:at`, `:align`, and `:pad` are now field options, so a custom type
  that took an option under one of those names no longer receives it. Every
  other option is still passed through untouched. Rename the option in the type,
  or read the value from one of the field options that now owns the name.

### Dates and times that are not ISO 8601

- Add the field option `:format`, taking `Calendar.strftime/3`'s directives, so
  that one declaration both reads and writes: `field :invoiced_on, :date,
  format: "%d/%m/%Y"`. Give a list to read a source that uses more than one
  spelling; the first is the one written.
- Check a format when the schema compiles: a directive that cannot be read back
  such as `%A`, a format that never states what its type needs such as `"%Y-%m"`
  for a `:date`, and a format on a type that has none are all build failures.
- Read `%y` through the POSIX century window, where 69-99 are the 1900s and
  00-68 the 2000s. Documented as the guess it is.
- This reverses part of the documented refusal of locale-specific values. A
  thousands separator and a currency symbol are still a custom type's business.

### Other formats and comments

- Add the `:psv` and `:ssv` format names, for pipe- and space-separated files.
- Add `comment: "#"`, which discards a commented line while the file is being
  framed, before any cell is read, so a commented line may hold an unclosed
  quote. Fixed-length blocks have no lines and so have no comments.

### Fixed-width layouts

- Add `layout: :fixed`, where a field is a range of bytes rather than a cell.
  Declare positions 1-based and inclusive, as a file specification writes them:
  `field :account, :string, at: 8..15`.
- Add the field options `:at`, `:align`, and `:pad`. Alignment defaults to the
  right for `:integer`, `:float`, and `:decimal`, and to the left otherwise.
- Add `record_length: N` for a file with no line terminators, alongside the
  default `record_length: :line`.
- Read an all-pad field as its pad value and a blank one as no value, so that
  `"00000000"` is zero and `"        "` is `nil`. Write `nil` blank whatever the
  field's pad, so that the two survive a round trip.
- Refuse, rather than guess at, a record that ends before a declared field
  (`:record_too_short`), a field whose bytes are not valid UTF-8
  (`:invalid_encoding`), and a value wider than the field that must hold it
  (`:value_too_wide`).
- Check positions when the schema is compiled: a field with no position, two
  fields covering the same bytes, a field beyond the declared record length, and
  a position declared on a delimited schema are all build failures.
- Reverse the documented refusal of fixed-width files in `README.md` and
  `AGENTS.md`.

### Dependencies

- Accept Decimal 3.x as well as 2.x for the optional `:decimal` dependency. The
  API this library uses is unchanged across the major version; the test suite
  passes against 2.0.0, 2.4.1, and 3.1.1.
- Document that the version resolved decides what a hostile number does.
  Decimal 3.0 made the IEEE 754 decimal128 limits its defaults, so a cell
  holding `1e1000000000` is refused as it is read; 2.x accepts it and renders
  it in full when writing. `Delimited.Type` and the README now say so, and
  recommend 3.x for files from an untrusted source.

## 0.1.0

- Add `Delimited.Schema`, declaring the columns of a delimited file as a struct
  with `delimited_schema/3` and `field/3`.
- Add `Delimited.read/3`, `read!/3`, `stream/3`, `decode/3`, and `decode!/3` for
  reading, and `write/4`, `write!/4`, and `encode!/3` for writing.
- Add a resumable RFC 4180 parser that reads a file in slices, reports the line
  and column of a failure, and reads the same rows however the input is sliced.
- Add the built-in types `:string`, `:integer`, `:float`, `:boolean`, `:date`,
  `:time`, `:naive_datetime`, `:utc_datetime`, `:decimal`, and `{:enum, values}`,
  and the `Delimited.Type` behaviour for declaring others.
- Add `Delimited.Dialect`, covering the delimiter, quote character, header row,
  null strings, trimming, skipped rows, line ending, byte order mark, and
  formula escaping.
- Add `Delimited.Error`, carrying a reason to match on and a message that states
  the next action.
