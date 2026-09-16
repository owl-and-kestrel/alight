#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Alight"
BUNDLE_ID="com.owlandkestrel.alight"
MIN_SYSTEM_VERSION="14.0"
UPDATE_CHANNEL="${ALIGHT_UPDATE_CHANNEL:-stable}"
SPARKLE_FEED_URL="${ALIGHT_SPARKLE_FEED_URL:-https://updates.owlandkestrel.com/alight/$UPDATE_CHANNEL/appcast.xml}"
BUILD_CONFIGURATION="${ALIGHT_BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_PUBLIC_KEY_FILE="${ALIGHT_SPARKLE_PUBLIC_KEY_FILE:-$ROOT_DIR/config/sparkle-ed25519.pub}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

if [[ ! "$UPDATE_CHANNEL" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
  echo "ALIGHT_UPDATE_CHANNEL contains an invalid channel slug." >&2
  exit 2
fi
if [[ ! "$SPARKLE_FEED_URL" =~ ^https://[A-Za-z0-9./:_-]+$ ]]; then
  echo "ALIGHT_SPARKLE_FEED_URL must be a simple HTTPS URL without credentials or query parameters." >&2
  exit 2
fi
if [[ ! -f "$SPARKLE_PUBLIC_KEY_FILE" ]]; then
  echo "Sparkle public key is missing: $SPARKLE_PUBLIC_KEY_FILE" >&2
  exit 2
fi
SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE")"
if [[ ! "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "Sparkle public key is not a canonical Ed25519 public key." >&2
  exit 2
fi

VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT_DIR/package.json")"
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,3}$ ]]; then
  echo "package.json contains an invalid app version: $VERSION" >&2
  exit 2
fi
PACKAGE_BUILD_NUMBER="$(/usr/bin/plutil -extract build raw -o - "$ROOT_DIR/package.json")"
BUILD_NUMBER="${ALIGHT_BUILD_NUMBER:-$PACKAGE_BUILD_NUMBER}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "package.json contains an invalid monotonically increasing build number: $BUILD_NUMBER" >&2
  exit 2
fi
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
  SOURCE_DIRTY="true"
else
  SOURCE_DIRTY="false"
fi
if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
  echo "ALIGHT_BUILD_CONFIGURATION must be debug or release." >&2
  exit 2
fi

swift build -c "$BUILD_CONFIGURATION"
BUILD_BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "SwiftPM did not stage Sparkle.framework beside the built executable." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"

# SwiftPM links Sparkle at @rpath. The command-line build's development rpaths
# do not include an application bundle's Frameworks directory, so add the
# canonical bundle-relative path before the outer app signature is created.
if ! /usr/bin/otool -l "$APP_BINARY" | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY"
fi

if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  AUTOMATIC_UPDATES="true"
else
  # Development builds may check explicitly, but must never replace themselves
  # from the public stable channel in the background.
  AUTOMATIC_UPDATES="false"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>AlightUpdateChannel</key>
  <string>$UPDATE_CHANNEL</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <$AUTOMATIC_UPDATES/>
  <key>SUAutomaticallyUpdate</key>
  <$AUTOMATIC_UPDATES/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUSignedFeedFailureExpirationInterval</key>
  <integer>0</integer>
  <key>AlightBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION</string>
  <key>AlightSourceCommit</key>
  <string>$SOURCE_COMMIT</string>
  <key>AlightSourceDirty</key>
  <$SOURCE_DIRTY/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

# Preserve Sparkle's nested bundle signatures and sign only the host app. Deep
# re-signing can invalidate Sparkle's XPC/updater components.
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --build|build)
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
