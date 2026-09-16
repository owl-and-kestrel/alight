import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const cli = path.resolve("bin/alight.mjs");

test("manual state can be rendered without fetching", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alight-"));
  const state = path.join(dir, "state.json");
  const resetAt = Math.floor(Date.now() / 1000) + 3600;

  const manual = await execFileAsync(process.execPath, [
    cli,
    "manual",
    "--state",
    state,
    "--primary-used",
    "20",
    "--primary-reset-at",
    String(resetAt),
    "--json",
  ]);

  const manualStatus = JSON.parse(manual.stdout);
  assert.equal(manualStatus.ok, true);
  assert.equal(manualStatus.source, "cache");
  assert.equal(manualStatus.windows[0].label, "5h");

  const swiftbar = await execFileAsync(process.execPath, [cli, "swiftbar", "--state", state, "--no-fetch"]);
  assert.match(swiftbar.stdout, /^Alight /);
  assert.match(swiftbar.stdout, /5h:/);
});

test("weekly-only Codex primary window is labeled from its duration", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alight-"));
  const state = path.join(dir, "state.json");
  const resetAt = Math.floor(Date.now() / 1000) + 6 * 24 * 3600;
  fs.writeFileSync(state, JSON.stringify({
    payload: {
      rate_limit: {
        primary_window: {
          used_percent: 10,
          reset_at: resetAt,
          limit_window_seconds: 7 * 24 * 3600,
        },
        secondary_window: null,
      },
    },
  }));

  const output = await execFileAsync(process.execPath, [cli, "status", "--state", state, "--no-fetch", "--json"]);
  const status = JSON.parse(output.stdout);

  assert.equal(status.windows.length, 1);
  assert.equal(status.windows[0].label, "Weekly");
  assert.doesNotMatch(status.summary, /5h/);
});

test("Codex windows without an authoritative duration are ignored", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alight-"));
  const state = path.join(dir, "state.json");
  fs.writeFileSync(state, JSON.stringify({
    payload: {
      rate_limit: {
        primary_window: {
          used_percent: 10,
          reset_at: Math.floor(Date.now() / 1000) + 3600,
        },
      },
    },
  }));

  const output = await execFileAsync(process.execPath, [cli, "status", "--state", state, "--no-fetch", "--json"]);
  const status = JSON.parse(output.stdout);

  assert.equal(status.ok, false);
  assert.deepEqual(status.windows, []);
});
