# Review doctrine — Go

Loaded for any repo with a `go.mod` at its root or one directory below it
(monorepos keep it in `api/` etc.). Layers on top of the global doctrine;
severities and the output contract come from there.

## Type safety

- **No `any`, and no bare `interface{}`, in code this repo owns — Blocker.**
  Third-party signatures that force one (stdlib `encoding/json`, etc.) are
  consumed at the boundary and stop there; the value is converted to a concrete
  type immediately. An `any` in a parameter, field, or return type this repo
  declares is the violation, regardless of what forced it upstream.
- **Closed sets are typed enums.** A string field whose values come from a known
  set gets `type Foo string` plus exported constants in the project's enum
  home. Branch with `switch` on the enum, never `if x == "literal"`. Truly
  free-text fields (names, subjects, notes) stay `string` — the trigger is
  "closed set," not "short string."
- **The database column stays `varchar`; the typing lives in Go.** Any
  `CREATE TYPE ... AS ENUM` is a finding. Validation happens in code, not at the
  database level.
- **An enum value IS its displayed value.** Members are human-readable strings
  (`"Pending"`, `"ID Front"`) — what the user picks is what is stored,
  reported, and rendered. A code/key + label split is the violation in every
  form it takes: a `Code`/`Label` pair on a model, a database-backed vocabulary
  table behind a closed set, or a map from enum value to display string.
  Renaming a member is a migration, and that cost is the point.
- **One declaration per enum value.** No package may declare a constant
  mirroring an enum member's value, however the comment explains it. Cast at
  the call site (`string(enums.X)`) when a signature takes a plain string. This
  extends across wire and model-facing boundaries: a tool schema's allowed
  values are DERIVED from the enum's values, and inbound strings are parsed by
  the enum's existing `FooFromString` — never a parallel token set plus a
  hand-rolled mapping switch.
- **No open enum-like unions** anywhere the repo carries a typed vocabulary — a
  union with an open `| string` tail typechecks nothing. Out-of-vocabulary wire
  data is handled by a runtime check, not a type-level escape hatch.
- **Boundary constructor.** A value entering from outside (HTTP, JSON, env, DB
  scan) is converted with `FooFromString(s) (Foo, error)` and rejected at the
  edge, so downstream code can trust the type.
- **Stored enums implement `Scan` and `Value`.** An enum type used as a model
  column implements `sql.Scanner` and `driver.Valuer`: `Scan` converts the
  stored string through the enum's own `FooFromString` and returns its error,
  `Value` returns the string. Without them the database is the one boundary
  that bypasses the vocabulary, and a stored stray loads as a typed value the
  type says cannot exist. A stored enum missing the pair is a Blocker, and a
  comment beside it explaining the omission is an admission, not a mitigation.
  (Ruled 2026-09-09: "all enums need Scan and Value methods.")

## Interfaces and construction

- **The standard shape for anything exposing a behavior contract** (services,
  clients, repos, token sources): exported interface + unexported struct +
  exported constructor returning the INTERFACE, all in the implementer's
  package.
- **No compile-time interface assertions** (`var _ Iface = (*T)(nil)`). The
  constructor's return type is the guarantee. For test fakes, passing the fake
  into an interface-typed parameter or field is the same guarantee.
- **Interfaces are declared where the contract is owned, and consumers take
  them as-is.** This reconciles the "interfaces belong to the consumer" Go
  idiom with the recorded ruling that overrides it: **a consumer never declares
  a narrowed local interface listing just the methods it uses.** A consumer
  takes the shared interface directly as its struct field and constructor
  parameter. Test fakes EMBED the shared interface and override only the
  methods exercised — the embed satisfies the contract and anything unexpected
  panics loudly. The only interfaces legitimately declared at a call site are
  genuinely cross-cutting contracts that are not a slice of an existing shared
  interface, and those are declared once and shared too.
- **No optional capability interfaces discovered by type assertion** over this
  repo's own types (`if r, ok := x.(Reconciler); ok { … }`). The method goes on
  the main interface every implementer already satisfies; implementers that do
  nothing provide an explicit no-op, which is the honest statement of that
  fact. Capability-detection type asserts are for adapting third-party types
  only.
- **A service always behaves the same way.** No constructor flags, nil-able
  dependencies, or config fields that switch runtime behavior inside one
  implementation. Genuinely different behavior means a SECOND complete
  implementation of the same interface, picked once at startup by a single
  constructor reading config. If the interface is too broad for the second
  variant, the interface is wrong — split it, don't add optional methods.
- **Receiver kind is consistent per type**: value receivers for pure reads,
  pointer receivers only for types that legitimately hold mutable state — and
  that state is itself worth questioning. Services default to value receivers.
- **No `init()` functions.** Initialization is explicit; `init()` hides side
  effects.

## Context and errors

- **`context.Context` is propagated as the first parameter of every call that
  can block or do I/O, and is never stored in a struct.**
- **Every GORM query carries that context through `db.WithContext(ctx)`.** A
  query built from a bare `db` while a `ctx` is in scope is a finding.
- **Custom error types over sentinel errors.** Define typed errors carrying the
  relevant fields; check with `errors.Is` / `errors.As`.
- **Wrap at package boundaries with structured context** — the operation name
  and the relevant IDs and inputs. A bare `fmt.Errorf("failed to X")` crossing a
  package boundary is a finding.
- **A boundary wrap carries a stack trace.** Wrap with `errors.Wrap` or
  `errors.Wrapf` from `github.com/pkg/errors`, or with a custom error type that
  records one; the trace is what a boundary wrap is for. Stdlib `errors`
  records no trace, which makes `pkg/errors` the one recorded exception to the
  Stdlib first rule.
- **Split validation from server failure at the service boundary:**
  `(result, validationErr, serverErr)` with the server error LAST, so the
  caller branches without sniffing types or message strings. Repos that only
  bubble database errors return a single error.
- **Capture the error on its own line, then check it.** `err = doThing(...)`
  followed by `if err != nil`, never the inline-scoped `if err := doThing();
  err != nil` form. This deliberately reverses the common Go idiom; do not
  "correct" it back.
- **Named return values whenever a function returns multiple values of the same
  type** (`(validationErr, serverErr error)`, `(scanDir, doneDir string)`),
  including in interface method declarations. Positional same-type returns are
  unreadable at the call site.
- **Log values, never pointers.** A pointer argument to a log call prints an
  address and answers no diagnostic question — dereference with a nil guard.
  Keep each log call on a single line, however long.

## Construction, validation, and mutation

- **`Create`/`Update` are validators and builders; a single `Save` is the only
  write.** They take a request, validate it, build or mutate an in-memory
  value, and return it. No I/O inside them.
- **`Create` maps the request onto the model 1:1 and nothing more.** No
  rule lookups, no prefix matching on identifiers, no "while we're here, also
  append X." Hidden derivation makes the emitted shape invisible to a reader of
  `Create`, and couples a generic builder to domain rules. If an action must
  assert several things at once, WIDEN the request to carry them and let the
  caller fill it.
- **One request type per resource, declared with the model.** This rule's
  subject is RESOURCE request types: a struct bound from a resource route to
  build or mutate a model. A resource's request type is declared where its
  model is declared, never in a controller or handler package, and there is
  exactly one of it. Which fields a client may set is expressed on that one
  struct (a json tag exposes a field, `json:"-"` hides one), so adding a write
  path means tagging a field, not declaring a second struct. A
  controller-local request struct, or a second request struct for a resource
  that already has one, is a Blocker regardless of the rationale written
  beside it. A required-field question about a request is answered by the
  owning repo or service's validation, never by a `binding:"required"` tag.
  Protocol payloads that bind no model (an OAuth or OIDC token, logout, or
  authorize body, form- or query-encoded) are outside this rule and are
  named as exceptions in a repo's own layer.
- **Controllers and handlers bind and format only.** A handler binds the
  request, calls the owning service or repo, and shapes the response. A
  validation check, a query, a domain decision, or a mutation inside a handler
  is a finding.
- **Server-owned identity is the exception in the other direction**: ids and
  derived storage keys are built by the owning layer, never accepted from a
  request, and are not assignable through `Update`. A request carrying one
  (beyond an id echoed per an explicit contract) is the violation, and so is a
  call site that computes one and assigns it around the create path.
- **Validation completeness is the contract; construction defaults are an
  implementation detail.** For every field the request can carry, and every
  column the schema requires: required fields enforced, closed-set strings
  checked against their enum, reference ids checked to exist, coupled fields
  validated together (a range is both-or-neither and ordered). "What happens if
  I pass a random UUID here?" must have a validation-error answer, not a
  database error and not a silently dangling row. Mechanical check: diff the
  schema's NOT NULL and closed-set columns against the validation accumulation
  — every required column appears, including server-owned ones. Coverage by
  "every creator stamps it" is NOT a substitute; Go zero values make the gap
  silent, since `""` satisfies a NOT NULL varchar.
- **Validation lives with the resource that OWNS the field.** The same check
  appearing in two places means the owning type is missing its validator — add
  it there and delegate, never copy.
- **Prefer non-conflicting writes to locking.** Pessimistic row locks convert a
  rare correctness bug into a user-visible timeout under load. In order: write
  only the columns the request touched; fold the precondition into the WHERE
  clause of a single UPDATE and check the affected-row count; optimistic
  concurrency with a version column; row locking only when the first three
  genuinely cannot work, presented with its timeout cost stated.
- **Field names map to their columns under GORM's default naming strategy.**
  A `gorm:"column:..."` override on an added line is a finding: a name that
  needs an override is the wrong name, so rename the field. Functional gorm
  tags (`gorm:"-"`, `foreignKey`, `references`) are unaffected. Existing
  overrides in a repo are a backlog for a sweep of their own, never precedent.

## Style

- **No anonymous structs with fields — anywhere, tests included.** Declare a
  named type. Empty `struct{}{}` is fine, and an embedded-fields-only alias
  struct for custom JSON marshalling is the one accepted idiom.
- **Struct literals declare fields explicitly, one field per line**, named
  never positional — including literals used as map keys or inside index
  expressions, where the clean fix is a named variable declared above. Maps,
  slices, and fieldless arrays are exempt; a struct HOLDING them is not. The
  one carve-out (ruled 2026-09-09): the rows of a test case table, a
  `[]namedCase{...}` literal whose cases run under `t.Run`, may keep their
  fields on one line, because a row reads as one case and the repo's tests
  universally use that shape. Every other struct literal, in test files
  included, stays one field per line.
- **No alias-only assignments** (`x := y` with no transformation) — name the
  parameter or variable correctly at its source.
- **Never declare a variable used exactly once solely to take its address** —
  use the project's address-of helper.
- **No function-typed parameters where a plain value works.** A callback whose
  every call site passes a closure returning a pre-computable value is just a
  value; take the value.
- **Single-line function signatures.** Per-line-parameter signatures are a
  violation, and an existing one is never a licence to add another — a bad
  sibling pattern is not justification for repeating it.
- **Blocking or retrying I/O on a request goroutine is a finding by default.**
  Retry loops, sleeps, and unbounded external calls inside a request-path method
  belong out of band: queue, outbox row, or detached goroutine.

## Dependencies

- **Stdlib first.** A new dependency for something `net/http`, `encoding/json`,
  `errors`, or `context` already covers is a finding. New dependencies are
  justified on maintenance status, transitive weight, and licence.
- **Pinned versions in `go.mod`** — no floating ranges.
- **Flag removals too**: a dependency no longer imported but still declared is a
  finding.

## Tests

- **Test what this repo owns**, with the external dependency faked at the
  interface boundary — never test third-party behavior.
- **Table-driven tests when cases genuinely share a shape** — it is not a
  mandated default. When used: a NAMED case struct (never an anonymous
  `[]struct{...}` literal) and `t.Run` subtests.
- **Test naming: `Test<Function>_<scenario>_<expected>`.**
- **Every error is asserted.** After any `x, err := …` the next line is
  `require.Nil(t, err)` or `require.NotNil(t, err)` — no `_`, no exceptions.
  Inside loops, reuse the outer `err` with `=`, check it in the body, and give
  the assertion a message naming the iteration. Use `require`, not `assert`, so
  a failed setup stops rather than producing a nil-deref three lines later.
- **No helpers that hide assertions.** Helpers set up; assertions stay visible
  in the test body.
- **One test file per source file, named for it**: tests for `foo.go` live in
  `foo_test.go` in the same package. A verb- or feature-named test file holding
  tests for several source files is a finding. Shared fakes live in the
  package's single test-support file (`fakes_test.go`, or the one the package
  already has), never in another source file's test file.
- Test files are held to the same style rules as production code — anonymous
  case structs and swallowed errors are findings in tests too.

## Mechanical pass — run these over the diff's ADDED lines

Recall is not a detector. Resolve or justify every hit, and when one hits,
sweep the whole diff for the same shape.

- `\bany\b` and `interface\{\}` — every hit a Blocker unless it sits at a
  third-party boundary and stops there.
- `if (err|verr|serr) :=` — inline error capture.
- `\[\]struct \{`, `:= struct \{`, `range \[\]struct \{` — anonymous field
  structs.
- `^var _ ` — compile-time interface assertions.
- `^type .* interface` inside consumers and services — a subset of a shared
  interface is a violation.
- `func init\(` — forbidden.
- `gorm:"column:`, a column-name override; functional gorm tags do not match
  this pattern.
- One-line multi-field struct literals. The naive `\{[^{}]+, [^{}]+\}` net is
  BLIND to nesting (`Foo{a: map[k]v{}, b: map[k]v{}}` escapes it) — strip
  innermost `{}` pairs first, then re-apply, or match added lines containing
  `{` whose brace-stripped remainder still holds `field:` twice.
- Multi-line log calls: a `logger.*f(` line ending in `,`; and any log argument
  of pointer type.
- Disemvoweled names: `\brng\b`, `\bhdlr\b`, `\bmgr\b`, `\btsk\b` — extend the
  list whenever a new one is caught.
- Declare-then-address: a local declared and used exactly once as `&local`.
- Alias-only assignments: `:= [a-z][A-Za-z]*` with a bare identifier on the
  right.
- Duplicate declarations: for every `const`/`var` the diff ADDS, grep the whole
  repo for the same name and the same literal value. A second declaration
  anywhere is a finding.
- For every `*_test.go` the diff adds or modifies, a sibling `<name>.go` must
  exist in the same directory; allowlist `setup_test.go`, `fakes_test.go`,
  `helpers_test.go`, `main_test.go`.
