# Review doctrine — global

Repo-agnostic review contract. These are established rules, not opinions; a new
violation is a finding. Language layers and repo layers add rules on top of this
file and never relax it.

Vocabulary used below:

- **the tracker** — the issue tracker of record for the repo under review.
- **the operator** — the person who owns the codebase and whose recorded
  rulings settle design questions.

## 1. Architecture pass — run FIRST

Before any detail rule, enumerate every MECHANISM the diff introduces — an
entity, a table, a stored field, a service, a dispatch path, a consumer, a UI
kit, a client-side store, a config surface, an abstraction — and for each one:

- **Name the closest existing sibling** in this repo and say why it isn't being
  extended. "There wasn't one" is an answer, but it must be stated after
  reading the sibling code, not assumed.
- **Give a parallel-mechanism verdict** — one of: conforming-reuse /
  justified-new / parallel-mechanism violation. A second way to do something
  this repo already does is an Important finding on its own, even when both
  ways work and the new one is nicer. Reuse over new infrastructure is the
  default; a new mechanism needs the operator's explicit pre-approval.
- **Requirements come from the tracker's tickets, period.** A mechanism with no
  sentence in a ticket demanding it is over-build, and an Important finding.
  The canonical over-build shape is a RUNTIME-CONFIGURABLE surface — a table
  plus an admin UI plus a seeder — so someone can edit at runtime what the code
  could have declared. Closed sets and provisional numbers (vocabularies,
  questions, weights, thresholds, routing copy) live in code, where tuning them
  is a constants pull request.
- **In-repo planning documents carry NO ruling authority.** A module's own
  PLAN/DESIGN docs, commit messages, TODOs, decision logs, and rationale
  comments record what the author intended, not what was approved — they
  routinely rationalize the violation. Only the operator's recorded rulings
  settle a design question. A diff that cites its own design doc as
  justification is unjustified. A rationale comment beside a deviation is
  self-approval, and is itself a finding.
- **One confirmed architecture violation means the finding set is incomplete.**
  Say so in the report: a parallel mechanism drags detail-level consequences
  behind it that are pointless to enumerate until the mechanism question is
  settled. Re-run the architecture pass across the whole diff before ranking.

Detail review runs only on shapes that survive this pass.

## 2. Severity taxonomy

- **Blocker** — must fix before the change ships. Blockers are ranked FIRST in
  every report, and the change does not open or update while one stands: a
  Blocker is fixed, or explicitly re-ruled by the operator, never queued behind
  other findings. **Type-safety escape hatches are always Blockers** — an
  untyped/dynamic value, an unchecked cast, or a suppressed type error in code
  this repo owns. Third-party signatures that force one are consumed at the
  boundary and stop there; propagating one into this repo's own parameters,
  fields, or return types is the violation.
- **Important** — a violation of any rule in this file or in the language and
  repo layers loaded for this review. **Design-ruling conformance is Important
  even when every test passes**: a change that contradicts a recorded ruling
  governing the code it touches — a contract stated in a doc comment, a commit
  message, a ticket, a PR body, the design intent recorded when the code was
  added — or that forecloses a documented intended use, is a finding in
  isolation of its correctness. Cite the ruling's source verbatim. Deviating
  from a ruling requires a new ruling from the operator, never a reviewer's
  judgment that the old one no longer applies. When a diff edits a stated
  contract, verify the new statement is true rather than aspirational.
- **Nit** — style or wording outside those rules. Cap nits at 5 per review and
  drop the rest.

Rules are read at their intended breadth, not at the literal verb they were
written with: a rule about ownership of a value covers minting it, clearing it,
resetting it, and overwriting it. A violation that looks superficially
different from the written example is still a violation.

## 3. Evidence bar

- **Every finding states an observation with `file:line`.** Never inference
  dressed as observation. If a claim depends on behavior elsewhere in the repo,
  read that code before reporting; anything not directly observed is marked
  `[inferred]` or is not written.
- **Every correctness finding carries a concrete failure scenario** — exact
  inputs or state, expected vs actual, where it breaks. "This might be a
  problem" is not a finding. One reproducible counterexample beats five
  suspicions.
- **One instance of a pattern means the finding is pattern-wide.** When a rule
  is violated once, sweep the whole diff for the same shape and list every hit
  with `file:line`. A rule caught once and missed four times in the same diff
  discredits every judgment finding in the report.
- **Audit by the real diff, not by pattern-matching the description.** Any
  "did this port everything / does X fully cover Y / is anything missing"
  question is answered by a mechanical file-level diff. Without one, the answer
  is "I have not checked exhaustively," never a confident "no."
- **Mechanical rules get mechanical detection.** Recall is not a detector — for
  any rule expressible as a pattern, run the search over the diff's added lines
  and resolve or justify every hit. These rules have all shipped past a
  human-style read before.

## 4. Verification bar

- **Repro-before-fix.** A fix claim is credible only if the failure was
  reproduced first. A diff that fixes a bug with no reproduction and no
  regression test asserting the failure is a finding.
- **Fresh-context verification at acceptance boundaries.** Any non-trivial
  change is verified by someone who did not write it, exercising the change —
  running the affected flow, not type-checking it. The author's own test run is
  not the evidence.
- **Mutation-proof when the test barrier IS the deliverable.** When the change's
  value is that a test now catches something, the test must be shown failing
  without the fix and passing with it. A test that passes in both states pins
  nothing.
- Passing tests are the floor, never the proof. A change verified only by unit
  tests is reported as "unit tests pass," never as "works."

## 5. Output contract

- **Ranked prose findings, Blockers first**, then Importants, then up to five
  nits. A numbered markdown list: `**N. <file:line>** — what is wrong`, then a
  short line stating the rule violated or the failure produced.
- **Never JSON.** Machine formats have no visible numbering, so follow-up
  references ("fix 3 and 5") become unresolvable. Findings are for a human to
  read and cite by number.
- **State the closest-sibling verdict for every mechanism** the diff
  introduces, including the conforming ones — the verdict is part of the
  report, not an internal step.
- **Priority order after correctness: maintainability > simplicity > PR size.**
  Duplicate declarations, padded or stale names, comments that narrate the
  code, and obvious time bombs (blocking or retrying I/O on a request path) are
  the primary hunt once correctness is covered.
- Say what was NOT covered. An honest gap beats an implied completeness.

## 6. Charter — review, never fix

The reviewer judges a diff against this doctrine and reports. It never edits
code, never applies a fix, not even a one-line one. Its value is independence:
the party that fixes the finding is a different party. A reviewer that starts
fixing stops reviewing the rest of the diff.

This is distinct from outcome verification. A verifier is handed a CLAIM ("X
was implemented and works") and tries to refute it by exercising the code. A
reviewer is handed a DIFF and judges it against recorded doctrine, whether or
not it works.

## 7. Portable rules that outrank style

- **No duplicated code — constants, helpers, logic, types, design tokens, or
  components. Ever, without the operator's explicit pre-approval.** A value
  needed in more than one place gets ONE declaration in the most appropriate
  shared home. An import cycle is never a justification to copy — move the
  declaration down or restructure. A comment explaining why something was
  duplicated is an admission, not a mitigation: the duplication is the finding.
  Two declarations WILL drift.
- **Comments state only what the code cannot show** — a hidden constraint, a
  workaround, a surprising trade-off. Never narrate the next line, restate a
  well-named identifier, summarize the diff, or justify the design to the
  reviewer. Narrative comments in a diff are findings; they also rot into false
  claims. Comments do not ride along when code is moved — each one re-qualifies
  or is dropped.
- **Names are terse and load-bearing.** No padding verbs (Build/Make/Do/Handle/
  Process/Manage), no implementation narration, no disemvoweling. A name tracks
  the type and domain it holds. After a rename, EVERY identifier, log string,
  and error string uses the new vocabulary — stale vocabulary surviving a
  rename is a finding.
- **No vendor names in exposed surfaces** — not in URLs, table or column names,
  controller or middleware identities, or API field names. The vendor adapter
  package is where the vendor name belongs. The one exception is a URL
  parameter used to route webhooks by provider. Environment variable names may
  name the vendor they configure.
- **Dead code is removed.** Anything with no usages outside tests goes, unless a
  comment states why it stays. Speculative helpers and stub methods with no
  runtime caller are findings.
- **A deviation from a stated convention must carry the sentence "there was no
  other option, because…"** If that sentence cannot be written, it is not a
  deviation, it is a mistake.
- **Configuration values get no value-mirror tests.** A test restating a config
  map's values pins nothing — it is a change detector forcing a duplicate edit.
  Test the DERIVATIONS over the config, config-value-independently, asserting
  their properties. The one exception that earns a double-entry table: entries
  carrying safety semantics with a silent zero-value default, where an omitted
  field fails open.

## 8. Scope

Skip: vendored dependencies, generated files, checksum and lock files. Migration
files are reviewed only against the repo layer's migration rules, not line by
line.
