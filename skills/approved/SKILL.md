---
name: approved
description: Arm the write gate and execute the pending approved plan. Invoke when Aaron approves a plan and wants the agent to proceed; replaces touching .agents/plan-approved by hand.
# Arming is Aaron's deliberate act; Claude must never auto-load this skill.
disable-model-invocation: true
# The bang-injection line below runs through the Bash tool's permission
# check; without these exact-match grants the whole invocation aborts
# outside auto mode ("Shell command permission check failed"). Compound
# commands require every subcommand allowed, hence one rule per part.
allowed-tools: Bash(mkdir -p .agents) Bash(touch .agents/plan-approved)
---

!`mkdir -p .agents && touch .agents/plan-approved`

Gate armed; execute the pending approved plan
