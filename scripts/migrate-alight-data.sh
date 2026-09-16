#!/usr/bin/env bash
set -euo pipefail

MODE="preview"
if [[ "${1:-}" == "--apply" ]]; then
  MODE="apply"
elif [[ "${1:-}" != "" && "${1:-}" != "--preview" ]]; then
  echo "usage: $0 [--preview|--apply]" >&2
  exit 2
fi

USER_HOME="${HOME:?HOME must be set}"
OLD_DOMAIN="com.owlandkestrel.glideslope"
OLD_CACHE="$USER_HOME/Library/Application Support/Glideslope/usage-cache.json"
OLD_CLI_STATE="$USER_HOME/.codex-usage-pressure/state.json"
NEW_CLI_STATE="$USER_HOME/.alight/state.json"
OLD_CLAUDE_TOKEN="$USER_HOME/.glideslope/claude-token"
NEW_CLAUDE_TOKEN="$USER_HOME/.alight/claude-token"
OLD_ANTIGRAVITY_TOKEN="$USER_HOME/.glideslope/antigravity-token"
NEW_ANTIGRAVITY_TOKEN="$USER_HOME/.alight/antigravity-token"

has_defaults_domain() {
  defaults read "$1" >/dev/null 2>&1
}

is_regular_file() {
  [[ -f "$1" && ! -L "$1" ]]
}

is_valid_cli_state() {
  node --input-type=module - "$1" <<'NODE'
import { readFileSync } from "node:fs";

const file = process.argv[2];
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const validWindow = (value) => object(value)
  && typeof value.used_percent === "number" && Number.isFinite(value.used_percent)
  && typeof value.reset_at === "number" && Number.isFinite(value.reset_at)
  && typeof value.limit_window_seconds === "number" && Number.isFinite(value.limit_window_seconds)
  && value.limit_window_seconds >= 60;
try {
  const value = JSON.parse(readFileSync(file, "utf8"));
  const payloadWindows = value?.payload?.rate_limit;
  const manualWindows = value?.manual_windows;
  const hasPayload = object(payloadWindows)
    && Object.values(payloadWindows).some(validWindow);
  const hasManual = object(manualWindows)
    && Object.keys(manualWindows).length > 0
    && Object.values(manualWindows).every(validWindow);
  process.exit(value?.version === 1 && (hasPayload || hasManual) ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

echo "Alight data migration ($MODE)"
if [[ -e "$OLD_CACHE" ]] && ! is_regular_file "$OLD_CACHE"; then
  echo "cache: legacy path is not a regular file; refusing to read ($OLD_CACHE)"
elif [[ -e "$OLD_CACHE" ]]; then
  echo "cache: legacy native cache found; choose Import Settings on first Alight launch"
else
  echo "cache: no legacy cache found"
fi

if [[ -e "$OLD_CLI_STATE" ]] && ! is_regular_file "$OLD_CLI_STATE"; then
  echo "cli-state: legacy path is not a regular file; refusing to read ($OLD_CLI_STATE)"
elif [[ -e "$OLD_CLI_STATE" ]] && ! is_valid_cli_state "$OLD_CLI_STATE"; then
  echo "cli-state: legacy state is not valid Alight CLI JSON; refusing to copy ($OLD_CLI_STATE)"
elif [[ -e "$OLD_CLI_STATE" ]]; then
  if [[ -e "$NEW_CLI_STATE" ]]; then
    echo "cli-state: destination exists; refusing to overwrite ($NEW_CLI_STATE)"
  else
    echo "cli-state: copy $OLD_CLI_STATE -> $NEW_CLI_STATE"
  fi
else
  echo "cli-state: no legacy CLI state found"
fi

if has_defaults_domain "$OLD_DOMAIN"; then
  echo "settings: legacy settings found; choose Import Settings on first Alight launch"
else
  echo "settings: no legacy UserDefaults domain found"
fi

echo "credentials: no credential bytes are copied by this command"
for pair in \
  "$OLD_CLAUDE_TOKEN:$NEW_CLAUDE_TOKEN" \
  "$OLD_ANTIGRAVITY_TOKEN:$NEW_ANTIGRAVITY_TOKEN"; do
  old_path="${pair%%:*}"
  new_path="${pair#*:}"
  if [[ -e "$old_path" ]]; then
    echo "credentials: manually copy $old_path -> $new_path with mode 0600"
  fi
done

if [[ "$MODE" != "apply" ]]; then
  echo "Preview only. Re-run with --apply after reviewing the paths above."
  exit 0
fi

if is_regular_file "$OLD_CLI_STATE" && is_valid_cli_state "$OLD_CLI_STATE" && [[ ! -e "$NEW_CLI_STATE" ]]; then
  install -d -m 700 "$(dirname "$NEW_CLI_STATE")"
  cp -p "$OLD_CLI_STATE" "$NEW_CLI_STATE"
  chmod 600 "$NEW_CLI_STATE"
  echo "migrated CLI state"
fi

echo "Credential migration remains manual and read-only by design."
