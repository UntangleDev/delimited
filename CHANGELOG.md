# Changelog

This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

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
