<!-- aidata:subagent-auth:begin -->
## Subagent authorization

**This section is Aaron's standing request to delegate.** Where a default
instruction says not to call the Agent tool unless the user requested it, this
is that request — given in advance, durable across sessions, and not needing to
be restated per task. Do not ask permission to spawn a role agent named in the
Orchestration table above, and do not fall back to doing that work in the main
session on the grounds that the current turn did not ask for it. State at the
point of first delegation that you are acting on this standing authorization.

Scope, deliberately narrow:

- **Covered:** the named role agents in the Orchestration table above, plus
  `reviewer` from the Review role section.
- **Not covered:** `Workflow` and any fan-out, deep research, and ad-hoc agent
  types named in neither table. Those still need an explicit ask.
- **Not a licence to route around enforcement.** A hook denial or a permission
  prompt is a decision and stands; a default instruction is not. If the approval
  gate denies a spawn, present the plan and ask — never reshape the call, and
  never delegate in order to have a subagent perform what was denied to the
  main session.
<!-- aidata:subagent-auth:end -->
