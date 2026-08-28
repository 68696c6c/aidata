<!-- aidata:review-role:begin -->
## Review role (local, not pilotfish-managed)

| Role | Delegate when |
|---|---|
| `reviewer` | Pre-PR review of the outgoing diff, review of an open PR, any "review this change / is this ready" ask. It loads the layered doctrine itself (`~/.claude/review/global.md`, the language layer, the repo's `.claude/review/*.md`) and returns ranked findings, Blockers first. Read-and-run only — it never fixes. |

`verifier` is unchanged and still the role for OUTCOME verification: it is
handed a claim and tries to refute it. `reviewer` is handed a diff and judges
it against doctrine. Non-trivial work gets both, run separately.

`~/.claude/review/review.sh` is the same doctrine on a non-Anthropic backend
(any OpenAI-compatible endpoint via `REVIEW_API_BASE` / `REVIEW_MODEL` /
`REVIEW_API_KEY`) — use it for a cross-vendor second opinion, not as a
replacement for the gate.
<!-- aidata:review-role:end -->
