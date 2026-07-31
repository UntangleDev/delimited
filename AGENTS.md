# Project

Delimited reads and writes CSV, TSV, fixed-width, and other flat files through a
schema declared as a struct, in the manner of `Ecto.Schema`. The schema declares
columns; `Delimited` performs the operations.

Supported environment: Elixir 1.15 or later. No runtime dependencies. `:decimal`
is optional and needed only for the `:decimal` type.

## Boundaries

The library refuses, rather than guesses at, the following. Each refusal is
documented at the point a reader would look for the feature, and none of them
should be relaxed without a decision recorded here.

- A multi-character or non-ASCII delimiter. The parser decides on single bytes.
- A row whose length differs from the header row's, or a fixed-width record
  shorter than a declared field.
- A locale-specific number: a thousands separator or a currency symbol. A custom
  `Delimited.Type` is the answer. A locale-specific *date* is no longer refused;
  `:format` reads one, using `Calendar.strftime/3`'s directives so that a single
  declaration serves reading and writing.
- Any encoding other than UTF-8. The delimited parser is byte-oriented, so
  another encoding passes through into `:string` fields unchanged; the fixed
  layout refuses a field whose bytes are not valid UTF-8, because there the
  same input means the positions are being counted wrongly.
- A fixed-width layout in characters rather than bytes.

Fixed-width support was added in 0.2.0 and this list changed with it. A refusal
removed here must be removed from the README's "What it will not read" in the
same commit.

## Decisions worth knowing before changing the code

- **The parser must read the same rows however the input is sliced.** Rows
  completed before a failure are returned with that failure for the same reason.
  Both are covered by properties in `test/delimited/property_test.exs`; a change
  that breaks either is a change to the contract.
- **A parse failure ends the file; a cast failure fails one row.** After a
  misplaced quote no later row can be trusted, which is not true of one
  unreadable date.
- **A missing declared column is an error; an undeclared extra column is
  ignored.** A renamed column presents as the former, and would otherwise read
  as a whole column of `nil`.
- **Formula escaping is off by default**, against the usual secure-by-default
  rule, because it breaks the round trip. `Delimited.Dialect` records the
  reasoning; that documentation is the deviation's justification and must
  survive with the option.
- **Writing is the inverse of reading.** A one-column row holding no value is
  written quoted, because an empty line would read back as no row.
- **A layout decides only how a field finds its text.** `Delimited.Reader` and
  `Delimited.Writer` take the same values from the same fields either way; the
  layouts are told apart by whether a row's payload is a binary, and by nothing
  else. Adding a third layout should not need a change anywhere else.
- **In a fixed-width field, blank and zero-filled mean different things.**
  `"00000000"` is zero and `"        "` is absent, in both directions. Writing
  `nil` as the pad byte would state a number the row never held; reading an
  all-pad field as `nil` would lose a stated zero. Both halves of that rule are
  load-bearing and are covered by a round-trip property.
- **Positions are byte offsets.** These formats are ASCII. A field whose bytes
  are not valid UTF-8 is refused rather than mangled, because that is what
  counting characters rather than bytes produces.

## Sources of truth

- RFC 4180 for the format, with the deviations listed in `Delimited.Parser`.
- `Delimited.Dialect` for what every option means.
- `Delimited.Error` for the reasons, which are part of the public contract in a
  way that the messages are not.

## Engineering preferences

### Priorities, in order

1. **Correctness and safety.** A wrong answer delivered confidently is worse
   than an error. Where the two conflict, fail.
2. **Security.** Secure by default; insecure only by explicit, documented
   opt-out.
3. **Clarity.** Code is read far more than written and debugged under pressure.
4. **Performance.** Optimise only after a benchmark identifies a real cost.

Nothing below overrides these priorities.

### Robustness

- **Never silently discard input.** Raise on unknown options. Match
  exhaustively or fail loudly. Handle every return value.
- **Validate at the boundary, trust inside it.** Public functions defend
  themselves. Private functions assume their callers have validated input.
- **Rescue only what you can handle.** A blanket `rescue` that converts every
  exception into one error destroys the cause and stacktrace.
- **Let it crash applies to transient faults, not bad input.** Restarting with
  the same invalid state creates an infinite loop.
- **Errors carry a matchable reason.** Callers match the reason; humans read
  the message. Keep the reason stable because it is part of the API.
- **Every operator-facing error must state the next action.**

### Security

- Treat external input as hostile and logs as accessible to readers who must
  not see secrets. Redact a sensitive value where it enters the system.
- Fail closed. If a protective step cannot run, stop.
- Use `:crypto` primitives. Do not implement cryptographic primitives. Compare
  secrets with `:crypto.hash_equals/2`, not `==`.
- Never build atoms from external input. Use `String.to_existing_atom/1` and
  handle the specific `ArgumentError`.
- State what each defence does not cover. A misleading defence is worse than
  an absent one.

### Elixir idioms

Follow the standard library because it is the language shared by Elixir
readers.

- `fetch/2` returns `{:ok, value} | :error`. `fetch!/2` returns the value or
  raises. `get/3` takes a default.
- A function ending in `?` returns a boolean.
- A function ending in `!` raises instead of returning an error tuple and
  ordinarily has a non-bang sibling. The narrow exception is `new!` for
  exhaustively validated, immutable, programmer-owned configuration. Such a
  constructor must raise `ArgumentError` and must not parse hostile runtime
  input.
- Options are keyword lists. Data is a map. Do not mix their roles.
- Domain types are structs with `@enforce_keys`, not bare maps.
- Return tagged tuples. Reserve exceptions for programmer error and genuinely
  exceptional conditions.
- Pattern match in function heads. Prefer small clauses to a large `cond`.
- Use `with` for a happy path of dependent steps and `case` for real branches.
- Use pipelines for transformations of one subject. Do not pipe into a single
  call or pipe values that are not the subject.
- Add `@spec` to every public function. Use `@moduledoc false` for internal
  modules.
- Use behaviours for pluggable implementations and protocols for polymorphism
  over data shapes. One implementation justifies neither.
- Run `mix format`. Compile with `mix compile --warnings-as-errors`. If the
  project publishes documentation, run `mix docs --warnings-as-errors`.

### The BEAM

- **Processes are for concurrency, isolation, and state, not code
  organisation.** Use a module when the code needs no lifecycle or failure
  boundary.
- A `GenServer` serialises work through one mailbox. Use that property only
  when the design needs a serialisation boundary.
- Messages are copied between processes. Repeatedly passing large structures
  has a real cost; binaries larger than 64 bytes are reference counted.
- Bound mailboxes and ETS tables.
- Give every wait an explicit, considered timeout.
- Await or supervise every `Task`.
- Prefer ETS for shared, read-heavy state. Use `:persistent_term` only for
  write-once data because a write triggers global garbage collection.
- Use the process dictionary only for genuine ambient request-scoped context.
  Restore any value that the code replaces.

### API design

The common operation should be one call with no configuration. Add options for
less common cases and a documented escape hatch only when evidence requires
them.

- **No magic.** Do not add implicit global state, action at a distance, or
  hidden registration.
- **No ceremony.** Do not require a builder where a keyword list expresses the
  operation.
- **Provide one way to perform an operation.** A second path doubles the
  surface and lets contracts drift.
- **Hold each value in one place.** Derive values that can be derived.
- Name functions honestly about cost and effect. `get_or_create` is not `get`.
- Keep return values matchable, composable, and consistent on every path.
- Expose the minimum public surface. Every public function and struct field
  becomes a compatibility obligation.
- Fix a confusing implementation instead of hiding it behind another facade.

### Documentation

Use the `forensic-plain-english` skill when writing or revising README files,
guides, moduledocs, function documentation, operator-facing messages, and source
comments. Preserve every supported fact, distinction, and qualification. State
what the source does not establish instead of inventing detail.

Write for a reader at the call site who has not seen the implementation. The
reader can see what a line does. Document what the code is for, what it refuses
to do, and what breaks if someone changes a non-obvious decision.

- **Document the decision, not the mechanism.** Explain why a choice that looks
  arbitrary forms part of a contract.
- **Name the owner, never a copied value.** Point to the module responsible for
  a constant instead of reproducing the constant in prose.
- **Do not write countable facts.** Counts and line numbers become false after
  ordinary edits.
- **Spend words on hazards.** Document failures that produce plausible wrong
  answers because other checks will not reveal them.
- **State what a module refuses to do.** Prevent a reader from inferring a
  guarantee that does not exist.
- **Explain non-obvious ordering.** State why reordering would break the
  required property.
- **Justify each deviation from these preferences where it occurs.**
- **Keep comments as honest as the README.** State narrow coverage next to the
  code that provides it.
- `@moduledoc false` does not excuse missing internal rationale. Use source
  comments for maintainers and `@doc` for call-site help.

Do not reference GitHub issues, pull requests, discussions, or their URLs in
source comments, moduledocs, guides, README files, or changelogs. Durable
documentation must state the current invariant, failure mode, or design reason
without depending on external discussion history.

Links to standards, RFCs, CVEs, official documentation, and internal guide
sections are allowed.

### Restraint

- **Less is more, but never less than necessary.** Do not remove load-bearing
  code in the name of simplicity.
- Build an abstraction when another real caller reveals the shared shape, not
  in anticipation of one.
- Before version 1.0, prefer deletion to deprecation.
- When a change adds more than it removes, state why the added surface earns
  its maintenance cost.
- The correct answer is often no. An absent feature has no bugs,
  documentation, or migration path.
