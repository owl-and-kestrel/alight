#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}"
PLUGIN_LINK="$PLUGIN_DIR/alight.1m.sh"

mkdir -p "$PLUGIN_DIR"
chmod +x "$ROOT/bin/alight.mjs" "$ROOT/swiftbar/alight.1m.sh"

ln -sfn "$ROOT/swiftbar/alight.1m.sh" "$PLUGIN_LINK"

echo "Installed SwiftBar plugin:"
echo "$PLUGIN_LINK -> $ROOT/swiftbar/alight.1m.sh"
echo "Open SwiftBar and refresh plugins if it is already running."
