import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

// The omp counterpart of the Stop and Notification bell hooks install.sh
// merges into ~/.claude/settings.json (install_user_hooks). The two sound
// paths below are a hand copy of the two `afplay` commands there and are kept
// in step by hand; README.md names the grep that shows the drift. They are not
// shared with the Claude side because the command string there is the jq
// merge's idempotency key.

export default function (pi: ExtensionAPI) {
  const play = (sound: string) => {
    if (process.platform !== "darwin") return;
    pi.exec("afplay", [sound]).catch(() => undefined);
  };

  pi.on("session_stop", () => {
    play("/System/Library/Sounds/Glass.aiff");
  });

  pi.on("tool_approval_requested", () => {
    play("/System/Library/Sounds/Ping.aiff");
  });
}
