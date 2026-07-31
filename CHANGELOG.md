# Changelog

This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

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
