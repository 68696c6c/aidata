import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

// /approved: arm the write-gate and wake the agent in one keystroke. The
// marker path matches omp/hooks/write-gate.ts MARKER_REL and the Claude
// gate (<repo>/.agents/plan-approved): one marker per repo, whichever
// harness arms it; the exec runs in the session cwd, which is the repo the
// gate will check.
//
// The wake-up is an aside user message, never a steer: an approval must
// not interrupt in-flight work, so a busy session injects it at the next
// step boundary, while an idle session starts a turn immediately.
// (followUp was the plan's pick, but its idle drain is gated on an existing
// assistant/toolResult transcript tail: in a fresh session the message sits
// queued until the user's next prompt, the exact bang-command buffering
// this command replaces. Deviation approved by Main 2026-10-28.)
// The instruction names no plan; the agent's standing rule resolves the
// single pending approved plan. The Claude counterpart is the `approved`
// skill (skills/approved/SKILL.md), whose bang-injection line arms the same
// marker before the model sees the prompt.

const ARM_CMD = "mkdir -p .agents && touch .agents/plan-approved";
const INSTRUCTION = "Gate armed; execute the pending approved plan";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("approved", {
    description: "Arm the write gate (.agents/plan-approved) and execute the pending approved plan",
    handler: async (_args, ctx) => {
      const res = await pi.exec("sh", ["-c", ARM_CMD], { cwd: ctx.cwd });
      if (res.code !== 0) {
        if (ctx.hasUI) {
          ctx.ui.notify(`gate arm failed: ${res.stderr.trim() || res.stdout.trim() || `exit ${res.code}`}`, "error");
        }
        return;
      }
      pi.sendUserMessage(INSTRUCTION, { deliverAs: "aside" });
    },
  });
}
