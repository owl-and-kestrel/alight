# Glideslope TODO

## Usage history (attribution), not just a live gauge

Glideslope currently shows only the latest usage reading per provider. Persist a
local history so a quota that "ticked down to 0" can be explained after the fact.

- Sample the same Codex/Claude usage endpoints Glideslope already polls and append
  `(timestamp, provider, limit_id, window, used_percent, resets_at)` to a local
  ledger (SQLite or JSONL under `~/Library/Application Support/Glideslope/`).
- Join the timeline against Codex's own local evidence: every rollout under
  `~/.codex/sessions/YYYY/MM/DD/*.jsonl` carries `token_count` events with a
  `rate_limits` snapshot (`used_percent`, `resets_at`) plus a `session_meta`
  (`originator`: `Codex Desktop` / `codex_exec` / `codex_cli_rs` / `codex_work_desktop`,
  and `cwd`). Charging each used_percent delta to the session that emitted the
  next observation attributes ~100% of a window's burn by originator + working
  directory with no extra instrumentation (prototype: 2026-09-02 analysis of the
  Sep 1 burn-to-zero).
- Dropdown: "last 24h / this window" burn broken down by originator + cwd, and a
  sparkline of used_percent across the window.
- Export the ledger as JSON so Astra's quota governor can replace its configured
  200bp/admission Codex cost estimate with a measured one (see
  astra/docs/investigations/astra-codex-quota-leak-2026-09-01.md).
