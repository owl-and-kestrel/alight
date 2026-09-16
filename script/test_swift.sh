#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
FRAMEWORKS_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
DEVELOPER_LIB_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"

if [[ ! -d "$FRAMEWORKS_DIR/Testing.framework/Modules/Testing.swiftmodule" ]]; then
  XCODE_TESTING_FRAMEWORKS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
  if [[ -d "$XCODE_TESTING_FRAMEWORKS/Testing.framework/Modules/Testing.swiftmodule" ]]; then
    FRAMEWORKS_DIR="$XCODE_TESTING_FRAMEWORKS"
  fi
fi

if [[ -d "$FRAMEWORKS_DIR/Testing.framework/Modules/Testing.swiftmodule" ]]; then
  exec swift test "$@" \
    -Xswiftc -F \
    -Xswiftc "$FRAMEWORKS_DIR" \
    -Xswiftc -I \
    -Xswiftc "$FRAMEWORKS_DIR/Testing.framework/Modules" \
    -Xlinker -F \
    -Xlinker "$FRAMEWORKS_DIR" \
    -Xlinker -framework \
    -Xlinker Testing \
    -Xlinker -rpath \
    -Xlinker "$FRAMEWORKS_DIR" \
    -Xlinker -rpath \
    -Xlinker "$DEVELOPER_LIB_DIR"
fi

# Full Xcode toolchains normally expose Swift Testing without additional search
# paths. Keep that standard path portable for contributors who are not using
# the standalone Command Line Tools package.
exec swift test "$@"
