import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const script = path.resolve(import.meta.dirname, "../scripts/migrate-alight-data.sh");

test("data migration preview is read-only and does not copy credentials", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "alight-migration-preview-"));
  const oldCache = path.join(home, "Library/Application Support/Glideslope/usage-cache.json");
  const newCache = path.join(home, "Library/Application Support/Alight/usage-cache.json");
  await mkdir(path.dirname(oldCache), { recursive: true });
  await writeFile(oldCache, "historical-cache", { mode: 0o600 });

  const result = await execFileAsync("bash", [script, "--preview"], { env: { ...process.env, HOME: home } });
  assert.match(result.stdout, /Preview only/u);
  assert.match(result.stdout, /no credential bytes are copied/u);
  await assert.rejects(stat(newCache), { code: "ENOENT" });
  assert.equal(await readFile(oldCache, "utf8"), "historical-cache");
});

test("data migration applies valid CLI state once and preserves the legacy source", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "alight-migration-cli-"));
  const oldState = path.join(home, ".codex-usage-pressure/state.json");
  const newState = path.join(home, ".alight/state.json");
  await mkdir(path.dirname(oldState), { recursive: true });
  const state = {
    version: 1,
    manual_updated_at: "2026-09-16T00:00:00.000Z",
    manual_windows: {
      primary_window: { used_percent: 20, reset_at: 1_779_030_000, limit_window_seconds: 18_000 },
    },
  };
  await writeFile(oldState, `${JSON.stringify(state)}\n`, { mode: 0o600 });

  const result = await execFileAsync("bash", [script, "--apply"], { env: { ...process.env, HOME: home } });
  assert.match(result.stdout, /migrated CLI state/u);
  assert.deepEqual(JSON.parse(await readFile(newState, "utf8")), state);
  assert.deepEqual(JSON.parse(await readFile(oldState, "utf8")), state);
  assert.equal((await stat(newState)).mode & 0o777, 0o600);

  await chmod(newState, 0o600);
  const replay = await execFileAsync("bash", [script, "--apply"], { env: { ...process.env, HOME: home } });
  assert.match(replay.stdout, /cli-state: destination exists; refusing to overwrite/u);
  assert.deepEqual(JSON.parse(await readFile(newState, "utf8")), state);
});
