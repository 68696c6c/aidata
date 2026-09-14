<!-- aidata:orchestrator-only:begin -->
## Orchestrator-only main session and plan files

The approval gate at `~/.claude/hooks/approval-gate.sh` enforces both rules; they extend the Orchestration table above.

- The main session is the orchestrator only and never changes files: no Edit/Write on repo or harness files, no git tree or history operations, no interpreter or heredoc edits, even when the gate is armed. Every change of any size goes to an executor with an exact spec. The approval gate enforces this mechanically (2026-09-08).
- A write-capable spawn (executor, mech-executor, security-executor, general-purpose) requires an approved plan file at `~/.claude/plans/<project>/<date>-<slug>.md` in the shape of `~/.claude/plans/TEMPLATE.md`: Goal, Out of scope, Design fit, Decisions with an Options line per decision, New surface, Steps, Verification, Fallback. The spawn prompt names the plan path; the gate refuses spawns without one and refuses a plan edited after arming. Plans state design choices as choices, with alternatives, before build steps (2026-09-08).
<!-- aidata:orchestrator-only:end -->