#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const DEFAULT_STATE_PATH = path.join(os.homedir(), ".alight", "state.json");
const DEFAULT_AUTH_PATH = path.join(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"), "auth.json");

function usage() {
  return `Usage:
  alight status [--json] [--no-fetch] [--state PATH] [--auth PATH]
  alight swiftbar [--no-fetch] [--state PATH] [--auth PATH]
  alight manual --primary-used PCT --primary-reset-at UNIX [--weekly-used PCT --weekly-reset-at UNIX]

The automatic path reads Codex auth from ~/.codex/auth.json and fetches ${USAGE_URL}.
Manual values are written to ~/.alight/state.json by default.`;
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      args._.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (key === "json" || key === "no-fetch" || key === "help") {
      args[key] = true;
      continue;
    }
    args[key] = argv[i + 1];
    i += 1;
  }
  return args;
}

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function writeJson(filePath, value) {
  ensureParent(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function coerceNumber(value) {
  const out = Number(value);
  return Number.isFinite(out) ? out : null;
}

function titleForDuration(seconds) {
  const minutes = Math.max(1, Math.round(seconds / 60));
  if (minutes === 7 * 24 * 60) return "Weekly";
  if (minutes % (24 * 60) === 0) return `${minutes / (24 * 60)}d`;
  if (minutes % 60 === 0) return `${minutes / 60}h`;
  return `${minutes}m`;
}

function normalizeWindow(name, window, nowMs = Date.now()) {
  const usedPercent = Math.max(0, Math.min(100, coerceNumber(window?.used_percent) ?? 0));
  const resetAt = coerceNumber(window?.reset_at);
  const reportedDuration = coerceNumber(window?.limit_window_seconds);
  if (!resetAt || reportedDuration === null) return null;
  const duration = Math.max(60, reportedDuration);

  const resetMs = resetAt * 1000;
  const secondsRemaining = Math.max(0, (resetMs - nowMs) / 1000);
  const expectedRemaining = Math.max(0, Math.min(1, secondsRemaining / duration));
  const actualRemaining = Math.max(0, Math.min(1, 1 - usedPercent / 100));
  const elapsed = Math.max(0, Math.min(1, 1 - expectedRemaining));
  const pressure = actualRemaining - expectedRemaining;

  return {
    id: name,
    label: titleForDuration(duration),
    used_percent: usedPercent,
    remaining_percent: actualRemaining * 100,
    expected_remaining_percent: expectedRemaining * 100,
    elapsed_percent: elapsed * 100,
    pressure_percent: pressure * 100,
    reset_at: resetAt,
    reset_after_seconds: secondsRemaining,
    limit_window_seconds: duration,
  };
}

function windowsFromPayload(payload, nowMs = Date.now()) {
  const rateLimit = payload?.rate_limit || {};
  return ["primary_window", "secondary_window"]
    .map((name) => normalizeWindow(name, rateLimit[name], nowMs))
    .filter(Boolean);
}

function windowsFromState(state, nowMs = Date.now()) {
  const payload = state?.payload;
  if (payload?.rate_limit) return windowsFromPayload(payload, nowMs);
  const manual = state?.manual_windows || {};
  return Object.entries(manual)
    .map(([name, window]) => normalizeWindow(name, window, nowMs))
    .filter(Boolean);
}

async function fetchUsage(authPath) {
  const auth = readJson(authPath);
  const token = String(auth?.tokens?.access_token || "").trim();
  const accountId = String(auth?.tokens?.account_id || "").trim();
  if (!token) {
    return { ok: false, error: "missing_codex_auth_token" };
  }

  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "User-Agent": "Alight/0.3",
  };
  if (accountId) headers["ChatGPT-Account-Id"] = accountId;

  try {
    const response = await fetch(USAGE_URL, { headers });
    const text = await response.text();
    let payload = null;
    try {
      payload = JSON.parse(text);
    } catch {
      return { ok: false, status: response.status, error: "non_json_response" };
    }
    if (!response.ok) {
      return { ok: false, status: response.status, error: payload?.error?.code || payload?.error?.message || "usage_fetch_failed" };
    }
    return { ok: true, status: response.status, payload };
  } catch (error) {
    return { ok: false, error: error?.message || String(error) };
  }
}

function worstWindow(windows) {
  if (!windows.length) return null;
  return [...windows].sort((a, b) => a.pressure_percent - b.pressure_percent)[0];
}

function classifyPressure(pressurePercent) {
  if (pressurePercent < -5) return "deficit";
  if (pressurePercent > 5) return "surplus";
  return "on track";
}

function formatPercent(value, digits = 0) {
  const rounded = Number(value).toFixed(digits);
  return `${rounded.replace(/\\.0$/, "")}%`;
}

function formatDuration(seconds) {
  const s = Math.max(0, Math.round(seconds));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

async function getStatus(options) {
  const statePath = options.state || DEFAULT_STATE_PATH;
  const authPath = options.auth || DEFAULT_AUTH_PATH;
  const state = readJson(statePath) || {};
  let source = "cache";
  let error = null;
  let payload = state.payload || null;

  if (!options["no-fetch"]) {
    const fetched = await fetchUsage(authPath);
    if (fetched.ok) {
      payload = fetched.payload;
      source = "live";
      writeJson(statePath, {
        version: 1,
        fetched_at: new Date().toISOString(),
        payload,
        last_error: null,
      });
    } else {
      error = fetched.error || `HTTP ${fetched.status}`;
    }
  }

  const windows = payload?.rate_limit ? windowsFromPayload(payload) : windowsFromState(state);
  const worst = worstWindow(windows);
  return {
    ok: windows.length > 0,
    source,
    error,
    generated_at: new Date().toISOString(),
    state_path: statePath,
    windows,
    worst,
    summary: worst ? `${worst.label} ${formatPercent(worst.pressure_percent, 0)} ${classifyPressure(worst.pressure_percent)}` : "usage unavailable",
  };
}

function renderSwiftBar(status) {
  if (!status.ok) {
    console.log("Codex ?");
    console.log("---");
    console.log("Usage unavailable");
    if (status.error) console.log(`Error: ${status.error}`);
    console.log("Fallback: run manual update");
    return;
  }

  const worst = status.worst;
  const sign = worst.pressure_percent > 0 ? "+" : "";
  const stale = status.source === "live" ? "" : " cached";
  console.log(`Alight ${sign}${formatPercent(worst.pressure_percent, 0)}${stale}`);
  console.log("---");
  for (const window of status.windows) {
    const windowSign = window.pressure_percent > 0 ? "+" : "";
    console.log(`${window.label}: ${formatPercent(window.remaining_percent, 0)} left, ${windowSign}${formatPercent(window.pressure_percent, 0)} ${classifyPressure(window.pressure_percent)}`);
    console.log(`  reset in ${formatDuration(window.reset_after_seconds)}`);
  }
  console.log("---");
  console.log(`Source: ${status.source}`);
  if (status.error) console.log(`Last fetch failed: ${status.error}`);
  console.log(`State: ${status.state_path}`);
}

function manualUpdate(args) {
  const statePath = args.state || DEFAULT_STATE_PATH;
  const primaryUsed = coerceNumber(args["primary-used"]);
  const primaryResetAt = coerceNumber(args["primary-reset-at"]);
  if (primaryUsed === null || primaryResetAt === null) {
    throw new Error("manual requires --primary-used PCT and --primary-reset-at UNIX");
  }
  const manual_windows = {
    primary_window: {
      used_percent: primaryUsed,
      reset_at: primaryResetAt,
      limit_window_seconds: coerceNumber(args["primary-window-seconds"]) || 5 * 3600,
    },
  };
  const weeklyUsed = coerceNumber(args["weekly-used"]);
  const weeklyResetAt = coerceNumber(args["weekly-reset-at"]);
  if (weeklyUsed !== null && weeklyResetAt !== null) {
    manual_windows.secondary_window = {
      used_percent: weeklyUsed,
      reset_at: weeklyResetAt,
      limit_window_seconds: coerceNumber(args["weekly-window-seconds"]) || 7 * 24 * 3600,
    };
  }
  writeJson(statePath, {
    version: 1,
    manual_updated_at: new Date().toISOString(),
    manual_windows,
  });
  return getStatus({ ...args, "no-fetch": true });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] || "status";
  if (args.help) {
    console.log(usage());
    return;
  }
  if (command === "status") {
    const status = await getStatus(args);
    console.log(args.json ? JSON.stringify(status, null, 2) : status.summary);
    return;
  }
  if (command === "swiftbar") {
    renderSwiftBar(await getStatus(args));
    return;
  }
  if (command === "manual") {
    const status = await manualUpdate(args);
    console.log(args.json ? JSON.stringify(status, null, 2) : status.summary);
    return;
  }
  throw new Error(`Unknown command: ${command}\n${usage()}`);
}

main().catch((error) => {
  console.error(error?.message || String(error));
  process.exitCode = 1;
});
