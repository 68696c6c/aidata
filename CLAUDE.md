# CLAUDE.md

## Context

Professional software engineering work across a polyglot stack for multiple clients and systems. Prioritize correctness, clarity, and maintainability over speed.

**CLAUDE.md hierarchy:** This is the root-level file. Client- and project-specific `CLAUDE.md` files exist at deeper levels and take precedence for their scope. When instructions conflict, the most specific (deepest) file wins. This file defines the baseline that all projects inherit.

---

## Tech Stack

**Languages:** TypeScript/JavaScript, Go, Python, Rust

**Frontend:** React, Next.js

**Backend:** Custom Go framework — Gin (HTTP), Cobra (CLI), Viper (config), GORM (ORM)

**Cloud & Infra:** AWS (S3, Aurora MySQL), Docker, Terraform, GitHub Actions

**Architecture:** Shared functionality via packages; monolith or microservices depending on context

---

## Code Standards

- **Strict quality** — full typing, linting, and tests; no shortcuts
- **Strict type safety** — no `any`, no `interface{}` without justification, no type assertions without checks; eliminate categories of runtime errors at compile time
- **Declarative over imperative** — prefer expressions over statements, data-driven configuration over procedural setup, and declarative APIs (SQL, HCL, JSX) over manual orchestration
- **Pure functions when possible** — avoid side effects and hidden state; isolate I/O at the edges; minimize indirection layers that obscure control flow
- **Always write tests** for new code unless explicitly told not to
- **Never add unrequested features** — do exactly what's asked, nothing more
- **Explain before changing architecture** — describe the approach and get confirmation first
- **Ask before switching patterns mid-task** — don't silently change conventions
- **Show only the changed function/block** with enough surrounding context to locate it — not full files, not raw diffs unless requested
- **When competing priorities conflict** — correctness > maintainability > simplicity > PR size
- **Uniformity across projects** — consistent code standards, tooling, linters, and dependency choices across all clients and repos; reduce cognitive overhead when switching contexts
- **Follow existing conventions** — when a project already has an established pattern, follow it even if you'd choose differently on a greenfield; flag concerns but don't unilaterally change
- **Scripts over prose documentation** — reusable scripts for common and critical operations (setup, migration, deployment, seeding) are better than comprehensive README instructions that go stale

---

## Error Handling & Debugging

- **Diagnose before fixing** — read error messages, logs, and stack traces before proposing changes; don't guess
- **Reproduce first** — confirm the failure case before writing a fix; suggest a reproduction step or test if one doesn't exist
- **Fix root causes, not symptoms** — if a nil check "fixes" a crash, explain why the value is nil in the first place
- **Go errors:** use custom error types or `pkg/errors` for wrapping with stack traces; avoid bare `fmt.Errorf` for anything that crosses package boundaries
- **Structured context on errors** — include relevant IDs, operation names, and inputs when wrapping; never wrap with just "failed to do X" and no context

---

## Git & PR Conventions

- **Conventional Commits** — `feat:`, `fix:`, `chore:`, `refactor:`, `test:`, `docs:` prefixes required
- **Scope when useful** — `feat(auth): add OIDC token refresh` over `feat: add OIDC token refresh` when the change is localized
- **One logical change per commit** — don't bundle unrelated fixes
- **PR size** — prefer small, reviewable PRs; split large changes into stacked PRs or sequential commits with clear boundaries
- **Branch naming** — `<type>/<short-description>` (e.g., `feat/oidc-refresh`, `fix/nil-pointer-user-service`)

---

## Dependencies

- **Prefer stdlib** over third-party when the stdlib solution is reasonable — don't add a library for something `net/http` or `encoding/json` already handles
- **Vet before adding** — justify any new dependency; consider maintenance status, transitive deps, and license
- **Pin versions** — no floating ranges in `go.mod`, `package.json`, or `requirements.txt`
- **One dependency, one purpose** — avoid "kitchen sink" utility libraries; prefer focused packages
- **Flag removals too** — if a dep is no longer needed, remove it; don't leave dead weight

---

## Testing

- **Isolated unit tests with mocked dependencies** — test your code, not third-party behavior; don't test what you don't own
- **Very high coverage on critical business logic** — auth flows, payment processing, data transformations, validation rules
- **Table-driven tests in Go when appropriate** — not a default; use when cases genuinely share a shape. Declare a named case struct (never an anonymous `[]struct{...}` literal — anonymous structs with fields are forbidden everywhere, tests included) and run cases with `t.Run` subtests
- **Mock at the interface boundary** — define interfaces for external dependencies; mock those, not concrete types
- **Test naming** — `Test<Function>_<scenario>_<expected>` (e.g., `TestCreateUser_duplicateEmail_returnsConflict`)
- **Test file colocation** — `*_test.go` next to the source in Go; `*.test.ts` next to the source in TypeScript
- **No test helpers that hide assertions** — keep assertions visible in the test body; helpers for setup only
- **Fail fast with clear messages** — use `t.Fatalf` / `t.Errorf` with descriptive messages, not bare `t.Fail()`

---

## Go-Specific Conventions

- **Always propagate `context.Context`** — first parameter, never stored in structs
- **Custom error types over sentinel errors** — define typed errors with relevant fields; use `errors.Is` / `errors.As` for checking
- **Wrap errors at package boundaries** — add context when crossing layers (handler → service → repo)
- **Interfaces belong to the consumer** — define interfaces where they're used, not where they're implemented
- **Pointer receivers for mutating methods, value receivers for pure reads** — be consistent per type
- **No `init()` functions** — use explicit initialization; `init()` hides side effects
- **GORM conventions** — choose field names that map cleanly under GORM's conventional naming strategy; never override with `gorm:"column:..."` tags (a name that needs an override is the wrong name); prefer `db.WithContext(ctx)` always
- **Gin handlers** — extract business logic into service layer; handlers do validation, binding, and response formatting only

---

## Application Design (12-Factor)

- **Config in the environment** — no hardcoded secrets, URLs, or feature flags; all configuration via environment variables or mounted config files
- **Strict dependency declaration** — all deps explicitly declared and isolated; no implicit reliance on system-level packages
- **Stateless processes** — no local state between requests; use external stores (DB, cache, object storage) for persistence
- **Port binding** — apps are self-contained and export services via port binding; no runtime dependency on an external app server
- **Dev/prod parity** — minimize gaps between development and production; same backing services, same Docker images, same configuration shape
- **Logs as event streams** — write structured logs to stdout; let the platform handle aggregation and routing
- **Fail fast on startup** — validate all required environment variables, config, and service connections at boot; crash immediately with clear errors rather than failing mysteriously at runtime

---

## DevOps & Infrastructure

- **Minimize external system-level dependencies** — if the app needs something beyond the language runtime, it must be explicitly installed in the Docker image; never assume host-level packages exist
- **Portability** — local development must mirror cloud execution as closely as possible; use Docker Compose or equivalent to run the full stack locally with the same images, env vars, and backing services
- **Infrastructure as Code** — all infrastructure managed via Terraform (or equivalent); no manual console changes, no ClickOps
- **Separate shared from application-specific infra** — base/shared infrastructure (VPC, DNS, shared DBs, CI runners) lives in its own IaC repo/module; application-specific infrastructure (app service, app-specific queues, buckets) is co-located with the application code
- **Reproducible builds** — Docker images are deterministic; pin base image tags, install specific dependency versions, avoid `latest`
- **CI/CD via GitHub Actions** — all builds, tests, and deployments are automated; no deploy process that requires manual steps beyond triggering the pipeline
- **Extract Action logic into local scripts** — any custom behavior in a GitHub Action should be a standalone script that can be run and tested locally; the Action step should just call the script. Faster iteration, easier debugging, no push-and-wait cycle

---

## Verification & External Claims

- **Never fabricate external claims. Trust-critical hard rule, not a style preference.** If I cannot quote a verifiable source for any external claim — UI breadcrumbs, menu labels, button names, panel names, keyboard shortcuts, API endpoints, request/response shapes, HTTP status codes, env var names a third-party tool reads, CLI flag syntax, vendor pricing tiers, dashboard URLs, support-portal paths, any third-party detail — I either WebFetch the vendor's current docs in the *same session*, or I say "I don't know without checking." Confidence from training data is not verification. Pattern-matching from prior projects is not verification. **No confidently-stated unverified breadcrumbs, ever**, regardless of how fast the user seems to need an answer. Pausing to verify costs seconds; fabrication costs trust and forces the user to catch the lie and re-prompt.
- **Mark unverified claims explicitly.** A `[verify]` placeholder or "I think X but haven't checked" is always acceptable. A guess presented in confident prose is not. If vendor docs are vague, contradictory, or behind auth — stop and ask, don't paper over with invention.
- **Failure-mode example to recognize.** Stating "DataGrip's `Database → Disconnect all` menu" as if it exists — it doesn't; the actual path (`View → Tool Windows → Services` → right-click data source → `Close All Sessions`) required WebFetch to find. The moment I feel confident enough to write a menu path / API shape / env var name / shortcut without having just verified it in the current session is the moment to stop and verify.
- **Prefer stable URLs over menu paths** — direct vendor URLs (e.g., `https://dashboard.stripe.com/settings/billing/portal`) survive UI reorganizations; navigation breadcrumbs rot. Include both when documenting a step.
- **Audit the whole doc when fixing one wrong path** — fabrication tends to be systemic, not local. If one breadcrumb is invented, suspect every other one in the same file until verified.
- **Same standard for external-API code** — verify endpoint URL, request/response shape, and status codes against current vendor docs, not against existing wrapper code in this repo (which itself may be stale).

---

## Communication Style

- Start with a concise high-level summary for context
- Use bullets for key points
- No filler phrases ("Great question!", "Certainly!", etc.)
- Be direct — assume technical fluency
- When saying "no" to a request, explain why and offer the alternative
