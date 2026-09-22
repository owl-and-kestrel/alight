#!/usr/bin/env bash
set -euo pipefail

# Packages the Glideslope → Alight bridge: the already-built release Alight.app
# re-wrapped as `Glideslope.app` inside `Glideslope.zip`, plus a signed appcast
# for the historical Glideslope feed.
#
# Why this shape: Sparkle installs an update into the host's existing path and
# finds the app inside the archive by the host's file name (or, failing that,
# by the host's bundle identifier). Installed Glideslope apps are named
# `Glideslope.app` with id `com.owlandkestrel.glideslope`, so an archive that
# only contains `Alight.app` is invisible to them. Shipping the identical Alight
# build under the old file name lets the old feed carry them across; on its
# first launch Alight renames the bundle to `Alight.app` (BridgeRelocation).
#
# This script never re-signs the app: the bundle bytes are the release build's.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist/release"
BRIDGE_DIR="$DIST_DIR/bridge"
APP_BUNDLE="$ROOT/dist/Alight.app"
LEGACY_APP_NAME="Glideslope"
ZIP_PATH="$BRIDGE_DIR/$LEGACY_APP_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
APPCAST_PATH="$BRIDGE_DIR/appcast.xml"
NOTES_PATH="$BRIDGE_DIR/$LEGACY_APP_NAME.md"
MANIFEST_PATH="$BRIDGE_DIR/glideslope-bridge.json"
RELEASE_CHANNEL="${ALIGHT_RELEASE_CHANNEL:-stable}"
DOWNLOAD_PAGE_URL="${ALIGHT_DOWNLOAD_PAGE_URL:-https://owlandkestrel.com/apps/alight}"
UPDATE_ORIGIN="${ALIGHT_UPDATE_ORIGIN:-https://updates.owlandkestrel.com}"
LEGACY_FEED_URL="${ALIGHT_BRIDGE_FEED_URL:-$UPDATE_ORIGIN/glideslope/$RELEASE_CHANNEL/appcast.xml}"
SPARKLE_PRIVATE_KEY_FILE="${ALIGHT_SPARKLE_PRIVATE_KEY_FILE:-/Users/jon/.config/owl-kestrel/secrets/sparkle-ed25519-private-key}"
SPARKLE_GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SPARKLE_SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Release bundle is missing: $APP_BUNDLE (run script/package_release.sh first)." >&2
  exit 1
fi

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_BUNDLE/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_BUNDLE/Contents/Info.plist")"
BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Contents/Info.plist")"
BUILD_CONFIGURATION="$(/usr/bin/plutil -extract AlightBuildConfiguration raw -o - "$APP_BUNDLE/Contents/Info.plist")"
SPARKLE_FEED_URL="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUILD_CONFIGURATION" != "release" ]]; then
  echo "Refusing to bridge a non-release Alight bundle." >&2
  exit 1
fi
if [[ "$BUNDLE_ID" != "com.owlandkestrel.alight" ]]; then
  echo "Bridge source must be the Alight bundle, found $BUNDLE_ID." >&2
  exit 1
fi
if [[ ! -f "$SPARKLE_PRIVATE_KEY_FILE" || "$(stat -f '%Lp' "$SPARKLE_PRIVATE_KEY_FILE")" != "600" ]]; then
  echo "Sparkle private key is missing or not mode 600: $SPARKLE_PRIVATE_KEY_FILE" >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_GENERATE_APPCAST" || ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
  echo "Sparkle release tools are missing. Run swift package resolve." >&2
  exit 1
fi

rm -rf "$BRIDGE_DIR"
mkdir -p "$BRIDGE_DIR"
STAGE="$(mktemp -d -t alight-bridge)"
trap 'rm -rf "$STAGE"' EXIT

# Same bytes, legacy file name. The ad-hoc seal covers the bundle contents, not
# the folder name, so the signature stays valid after the rename.
/usr/bin/ditto "$APP_BUNDLE" "$STAGE/$LEGACY_APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/$LEGACY_APP_NAME.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE/$LEGACY_APP_NAME.app" "$ZIP_PATH"

ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
ZIP_SIZE_BYTES="$(stat -f%z "$ZIP_PATH")"
ARTIFACT_URL="${ALIGHT_BRIDGE_ARTIFACT_URL:-$UPDATE_ORIGIN/glideslope/releases/v$VERSION/$ZIP_SHA256/$LEGACY_APP_NAME.zip}"
if [[ "${ARTIFACT_URL##*/}" != "$LEGACY_APP_NAME.zip" ]]; then
  echo "Bridge artifact URL must end in $LEGACY_APP_NAME.zip." >&2
  exit 1
fi
ARTIFACT_URL_PREFIX="${ARTIFACT_URL%/*}/"
printf '%s  %s\n' "$ZIP_SHA256" "$(basename "$ZIP_PATH")" > "$CHECKSUM_PATH"

cat > "$NOTES_PATH" <<NOTES
# Glideslope is now Alight $VERSION

Glideslope has been renamed Alight. This update installs Alight in place and
moves it to Alight.app; your settings can be imported on first launch. Future
updates arrive through Alight's own update channel.
NOTES

"$SPARKLE_GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$ARTIFACT_URL_PREFIX" \
  --link "$DOWNLOAD_PAGE_URL" \
  --embed-release-notes \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  --versions "$BUILD_NUMBER" \
  -o "$APPCAST_PATH" \
  "$BRIDGE_DIR"

APPCAST_ARTIFACT_URL="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
APPCAST_SIGNATURE="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
APPCAST_BUILD="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="version"])' "$APPCAST_PATH")"
if [[ "$APPCAST_ARTIFACT_URL" != "$ARTIFACT_URL" || "$APPCAST_BUILD" != "$BUILD_NUMBER" || -z "$APPCAST_SIGNATURE" ]]; then
  echo "Generated bridge appcast does not match the packaged artifact and build." >&2
  exit 1
fi
"$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$ZIP_PATH" "$APPCAST_SIGNATURE"
"$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$APPCAST_PATH"
APPCAST_SHA256="$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')"

# Non-secret description of the bridge for the publisher and for review.
ALIGHT_VERSION="$VERSION" \
ALIGHT_BUILD_NUMBER="$BUILD_NUMBER" \
ALIGHT_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
ALIGHT_ARTIFACT_URL="$ARTIFACT_URL" \
ALIGHT_ARTIFACT_SHA256="$ZIP_SHA256" \
ALIGHT_ARTIFACT_SIZE_BYTES="$ZIP_SIZE_BYTES" \
ALIGHT_LEGACY_FEED_URL="$LEGACY_FEED_URL" \
ALIGHT_APPCAST_SHA256="$APPCAST_SHA256" \
ALIGHT_TARGET_FEED_URL="$SPARKLE_FEED_URL" \
node <<'NODE' > "$MANIFEST_PATH"
const payload = {
  schema: "ok.product-bridge.v1",
  appId: "alight",
  legacyAppId: "glideslope",
  hostBundleId: "com.owlandkestrel.glideslope",
  bundleId: "com.owlandkestrel.alight",
  version: process.env.ALIGHT_VERSION,
  build: Number(process.env.ALIGHT_BUILD_NUMBER),
  channel: process.env.ALIGHT_RELEASE_CHANNEL,
  legacyFeed: { format: "sparkle.appcast.v2", url: process.env.ALIGHT_LEGACY_FEED_URL, sha256: process.env.ALIGHT_APPCAST_SHA256 },
  targetFeedUrl: process.env.ALIGHT_TARGET_FEED_URL,
  artifacts: [{
    platform: "macos",
    archiveAppName: "Glideslope.app",
    url: process.env.ALIGHT_ARTIFACT_URL,
    sha256: process.env.ALIGHT_ARTIFACT_SHA256,
    sizeBytes: Number(process.env.ALIGHT_ARTIFACT_SIZE_BYTES)
  }]
};
process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
NODE

echo "Created $ZIP_PATH"
echo "Wrote $CHECKSUM_PATH"
echo "Wrote $APPCAST_PATH"
echo "Wrote $MANIFEST_PATH"
