import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Boots the Hindsight memory server on session start when its API is not
// already serving, so the native `memory.backend: hindsight` wiring always
// finds it. One server is shared across concurrent omp sessions and
// deliberately outlives them — stop it with `pkill -f hindsight-api`.
//
// Configuration sources (no hardcoding):
//   apiUrl       — `omp config get hindsight.apiUrl` (omp-resolved: env and
//                  project overrides apply); the URL's port is passed to the
//                  server as HINDSIGHT_API_PORT so a non-default port works.
//   llmProvider / llmModel — hindsight.* keys in the user config.yml. omp's
//                  config registry is schema-closed and does not know them,
//                  so they are read from the file itself (omp config path).
//   API key      — .env at the aidata repo root (gitignored, mode 600):
//                  HINDSIGHT_API_LLM_API_KEY, then FIREWORKS_API_KEY, then
//                  the session's FIREWORKS_API_KEY as the last fallback.
// hindsight-api itself is installed by aidata's install.sh (pipx).
// Docs: https://hindsight.vectorize.io/developer/installation

const BIN = join(homedir(), ".local", "bin", "hindsight-api");
const LOG_DIR = join(homedir(), ".hindsight", "logs");
const DEFAULT_API_URL = "http://localhost:8888";
// This file lives at <repo>/omp/extensions/hindsight.ts and is loaded through
// a symlink from ~/.omp/agent/extensions/; realpath recovers the repo root.
const REPO_ROOT = dirname(dirname(dirname(realpathSync(fileURLToPath(import.meta.url)))));

// The `hindsight:` block of the user config.yml as a flat record. omp ignores
// keys outside its schema, and this parser is for exactly our file shape:
// top-level `hindsight:` followed by two-space-indented `key: value` pairs.
function hindsightFileConfig(): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    const dir = execFileSync("omp", ["config", "path"], { encoding: "utf8" }).trim();
    let inSection = false;
    for (const line of readFileSync(join(dir, "config.yml"), "utf8").split("\n")) {
      if (/^\S/.test(line)) inSection = line === "hindsight:";
      else if (inSection) {
        const m = line.match(/^\s+(\w+):\s*(\S.*?)\s*$/);
        if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
    }
  } catch {
    // omp CLI or config unreadable — callers fall back to defaults.
  }
  return out;
}

function dotenvValue(key: string): string | undefined {
  try {
    for (const line of readFileSync(join(REPO_ROOT, ".env"), "utf8").split("\n")) {
      const m = line.match(/^([A-Z0-9_]+)\s*=\s*(.*)$/);
      if (m?.[1] === key) return m[2].trim().replace(/^["']|["']$/g, "");
    }
  } catch {
    // No .env — caller falls back to the session environment.
  }
  return undefined;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    const cfg = hindsightFileConfig();
    let apiUrl = cfg.apiUrl ?? DEFAULT_API_URL;
    try {
      // omp-resolved value wins: it honors HINDSIGHT_API_URL and project
      // .omp/config.yml overrides, which the raw user file cannot see.
      const resolved = execFileSync("omp", ["config", "get", "hindsight.apiUrl"], {
        encoding: "utf8",
      }).trim();
      if (resolved) apiUrl = resolved;
    } catch {
      // Keep the file value (or default).
    }

    // Any HTTP response — even a 404 — means a server is listening; only a
    // connection failure throws.
    const up = await fetch(apiUrl + "/", { signal: AbortSignal.timeout(1500) })
      .then(() => true)
      .catch(() => false);
    if (up) return;

    if (!existsSync(BIN)) {
      ctx.ui.notify(`hindsight-api not installed at ${BIN} — run aidata/install.sh`, "warning");
      return;
    }
    const key =
      dotenvValue("HINDSIGHT_API_LLM_API_KEY") ??
      dotenvValue("FIREWORKS_API_KEY") ??
      process.env.FIREWORKS_API_KEY;
    if (!key) {
      ctx.ui.notify(
        "no HINDSIGHT_API_LLM_API_KEY/FIREWORKS_API_KEY in aidata/.env and FIREWORKS_API_KEY unset — memory server not started",
        "warning",
      );
      return;
    }

    mkdirSync(LOG_DIR, { recursive: true });
    const logFd = openSync(join(LOG_DIR, "server.log"), "a");
    ctx.ui.notify(
      `starting hindsight memory server (${apiUrl}; first run downloads ~220MB of models)…`,
      "info",
    );
    spawn(BIN, [], {
      detached: true,
      stdio: ["ignore", logFd, logFd],
      env: {
        ...process.env,
        HINDSIGHT_API_PORT: new URL(apiUrl).port || "8888",
        HINDSIGHT_API_LLM_PROVIDER: cfg.llmProvider ?? "fireworks",
        HINDSIGHT_API_LLM_MODEL: cfg.llmModel ?? "accounts/fireworks/models/gpt-oss-120b",
        HINDSIGHT_API_LLM_API_KEY: key,
      },
    }).unref();
  });
}
