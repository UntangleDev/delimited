# Benchmarks

Each script answers one question. Run one with:

```console
mix run bench/read.exs
```

| Script | The question it answers |
|---|---|
| `read.exs` | What does reading cost, and how much of it is parsing rather than casting? |
| `parser.exs` | Where does the parser's own time go — per byte, or per cell? |
| `write.exs` | What does writing cost, and how does the quoting policy change it? |
| `memory.exs` | How much result data does `read/3` retain when a stream consumer retains no rows? |
| `chunk_size.exs` | Is 65_536 the right default for `:chunk_size`? |
| `overhead.exs` | What does each declared feature cost? |

## Settings

| Variable | Default | For |
|---|---|---|
| `BENCH_ROWS` | 10000 | how many rows each fixture holds |
| `BENCH_TIME` | 3 | seconds per scenario |
| `BENCH_WARMUP` | 1 | seconds of warmup |
| `BENCH_SAVE` | — | a tag for the suite files saved under `bench/snapshots/` |
| `BENCH_LOAD` | — | a saved tag to compare this run against |

`BENCH_TIME=0 BENCH_WARMUP=0 BENCH_ROWS=100` disables timed sampling and uses
small fixtures. Benchee still executes each scenario once, which is how
continuous integration checks that the benchmarks still work.

To show a change cost nothing:

```console
BENCH_SAVE=before mix run bench/read.exs
# make the change
BENCH_LOAD=before mix run bench/read.exs
```

Rows are built from their own index rather than at random, so two runs on one
machine measure the same work. Scripts that contain several Benchee suites save
one file per suite, so a later suite does not overwrite an earlier one.

## What they found

Measured on an Apple M3 Max, Elixir 1.20.2 / OTP 28, with two seconds per
scenario after one second of warmup. Unless stated otherwise, the fixtures hold
10,000 rows of eight columns; the plain delimited fixture is 482 KiB. These
figures describe that machine, runtime and fixture. Run the scripts again before
relying on them after any of those changes.

**Reading is dominated by parsing, not by casting.** The delimiter state machine
takes 43 ms of the 72 ms total. Matching the header row and building structs
adds 23 ms. Turning eight text cells into integers, floats, a date, a boolean
and an enum adds about 6 ms. Optimise the parser before the built-in types unless
a new measurement changes that result.

**The parser costs per cell, not per byte.** The same 1.68 MB divided into eight
cells per row rather than one takes 4.2 times as long. Scanning for the next
delimiter is cheap; what happens at each one is not. That is where an
optimisation would have to go. The parser is 15.4 times slower than
`:binary.split/3` twice over. That split cannot quote, resume across slices or
track line numbers; it provides a lower bound, not an alternative parser.

**The quoted fixture took 1.05x as long as the plain fixture**, and the fixed
layout read 1.21x faster than the delimited layout.

**Writing got 4.3 times faster because of this suite.** The first run had
`quoting: :always` beating the default `:as_needed` by 1.7 to 1.9 times, which
is backwards: the default was doing more work than the option nobody sets.
`:as_needed` scans each cell for a delimiter, a quote or a line break. It handed
`:binary.match/2` a fresh four-element list every time, which compiles a pattern
on each call at thirty times the cost of the scan itself. Scanning those four
bytes by hand took the default write path from 67.2 ms to 15.5 ms. The default
is now 2.6 times faster than `:always`.

For this fixture, the delimited layout now writes 1.6 times faster than the
fixed one, having been 2.7 times slower before the fix. Padding every field took
more time than deciding whether to quote after the quoting fix.

**`chunk_size: 65_536` was the fastest tested size on this run.** The 16 KiB,
256 KiB, 4 KiB, 512-byte and 1 MiB sizes were 1.04x, 1.07x, 1.08x, 1.34x and
1.93x slower. This result does not justify changing the default. It does not
establish the best size for another machine or file shape.

**Rebuilding two embedded structs took 1.17x as long on this run.**
`Delimited.Schema` expands their fields when the schema compiles, so header
matching and casting still use a flat field list. The reader then rebuilds the
declared nested structs. This comparison measures that remaining work.

**A declared date format took 1.28x as long as ISO 8601 on this run.**
`Date.from_iso8601/1` uses a tighter parser than the declared format's directive
walk. The benchmark uses one row count, so it does not establish how the ratio
changes with input size.

**`trim: true` took 1.10x as long. `comment: "#"` took 1.02x as long** on this
run against a file with no comments.

**The result returned by `read/3` grows with the row count.** Results for 10,000,
20,000 and 40,000 rows occupy 2.29 MB, 4.58 MB and 9.16 MB. A stream consumed
with `Stream.run/1` returns `:ok`, whose measured size rounds to 0.00 MB. This
comparison measures completed calls' result terms. It does not measure transient
working memory or prove that `stream/3` holds one slice and one row while it
runs; the laziness test under `stream/3` checks that contract.

## A note on measuring result size

Benchee's memory figure is how much an invocation allocates in total, not how
much it retains. Measured that way `read/3` and `stream/3` come out within one
percent of each other, because they allocate the same rows; what differs is
whether the completed call returns those rows. `memory.exs` therefore measures
each result term with the ERTS debug term-size function.

Process memory did not produce a stable result. A process's heap capacity does
not shrink promptly after a collection, so the figure wanders by megabytes
between runs. The compiler can also report zero when the program never uses the
result.
