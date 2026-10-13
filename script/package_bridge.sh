#!/usr/bin/env bash
set -euo pipefail

# Packages the one-time Glideslope bridge for the historical Glideslope feed:
# the Glideslope 0.5.2 (12) rename-announcement build from commit 9df75478,
# the last Glideslope identity. It keeps com.owlandkestrel.glideslope, the old
# feed and the existing Sparkle key, so installed Glideslope apps update to it;
# on first launch it shows "Glideslope is now Alight" and opens the Alight page
# for a manual install. Nest's release-origin publisher admits exactly this
# identity (version, build, commit and the glideslope.git source URL, the
# repository's name before its in-place rename) and nothing newer, so current
# Alight bytes are never relabelled as Glideslope.
#
# Inputs:
#   ALIGHT_BRIDGE_SOURCE_COMMIT  bridge commit; must equal the Nest pin
#                                (scripts/release-manifest.mjs bridge-pin),
#                                which is also the default
#   ALIGHT_BRIDGE_SOURCE_DIR     optional clean checkout/worktree at exactly that
#                                commit; its dist/Glideslope.app is reused when
#                                it is a clean release build of that commit,
#                                otherwise it is built there. When unset, a
#                                temporary local clone of this repository at
#                                that commit is created and built.
# The historical build is a local `swift build` plus ad-hoc codesign (no
# Developer ID identity or notarization). The Sparkle Ed25519 key signs the
# archive and appcast, and the O+K key file signs the manifest; both are
# release-operator inputs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist/release"
BRIDGE_DIR="$DIST_DIR/bridge"
LEGACY_APP_NAME="Glideslope"
ZIP_PATH="$BRIDGE_DIR/$LEGACY_APP_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
APPCAST_PATH="$BRIDGE_DIR/appcast.xml"
NOTES_PATH="$BRIDGE_DIR/$LEGACY_APP_NAME.md"
PAYLOAD_PATH="$BRIDGE_DIR/glideslope-bridge.payload.json"
MANIFEST_PATH="$BRIDGE_DIR/glideslope-bridge.json"
RELEASE_CHANNEL="stable"
DOWNLOAD_PAGE_URL="${ALIGHT_DOWNLOAD_PAGE_URL:-https://owlandkestrel.com/apps/alight}"
UPDATE_ORIGIN="${ALIGHT_UPDATE_ORIGIN:-https://updates.owlandkestrel.com}"
LEGACY_FEED_URL="$UPDATE_ORIGIN/glideslope/$RELEASE_CHANNEL/appcast.xml"
SPARKLE_PRIVATE_KEY_FILE="${ALIGHT_SPARKLE_PRIVATE_KEY_FILE:-/Users/jon/.config/owl-kestrel/secrets/sparkle-ed25519-private-key}"
SPARKLE_GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SPARKLE_SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
RELEASE_MANIFEST_TOOL="$ROOT/scripts/release-manifest.mjs"

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

read -r PINNED_COMMIT PINNED_VERSION PINNED_BUILD < <(node "$RELEASE_MANIFEST_TOOL" bridge-pin)
BRIDGE_SOURCE_COMMIT="${ALIGHT_BRIDGE_SOURCE_COMMIT:-$PINNED_COMMIT}"
if [[ ! "$PINNED_COMMIT" =~ ^[0-9a-f]{40}$ || "$BRIDGE_SOURCE_COMMIT" != "$PINNED_COMMIT" ]]; then
  echo "ALIGHT_BRIDGE_SOURCE_COMMIT must be the pinned bridge commit $PINNED_COMMIT." >&2
  exit 1
fi

STAGE="$(mktemp -d -t alight-bridge)"
trap 'rm -rf "$STAGE"' EXIT

SOURCE_DIR="${ALIGHT_BRIDGE_SOURCE_DIR:-}"
if [[ -z "$SOURCE_DIR" ]]; then
  SOURCE_DIR="$STAGE/source"
  git clone -q --shared --no-checkout "$ROOT" "$SOURCE_DIR"
  git -C "$SOURCE_DIR" checkout -q --detach "$BRIDGE_SOURCE_COMMIT"
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

verify_source_tree() {
  local head
  head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  if [[ "$head" != "$BRIDGE_SOURCE_COMMIT" ]]; then
    echo "Bridge source HEAD $head is not the bridge commit $BRIDGE_SOURCE_COMMIT." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]]; then
    echo "Bridge source tree at $SOURCE_DIR is not clean." >&2
    exit 1
  fi
}

verify_source_tree
read -r SOURCE_VERSION SOURCE_BUILD < <(node -e 'const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); console.log(`${p.version} ${p.build}`);' "$SOURCE_DIR/package.json")
if [[ "$SOURCE_VERSION" != "$PINNED_VERSION" || "$SOURCE_BUILD" != "$PINNED_BUILD" ]]; then
  echo "Bridge source is $SOURCE_VERSION ($SOURCE_BUILD); only $PINNED_VERSION ($PINNED_BUILD) is admitted." >&2
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

APP_BUNDLE="$SOURCE_DIR/dist/$LEGACY_APP_NAME.app"
plist() { /usr/bin/plutil -extract "$1" raw -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true; }
is_clean_release_build() {
  [[ -d "$APP_BUNDLE" && "$(plist GlideslopeSourceCommit)" == "$BRIDGE_SOURCE_COMMIT" \
    && "$(plist GlideslopeSourceDirty)" == "false" && "$(plist GlideslopeBuildConfiguration)" == "release" ]]
}
if ! is_clean_release_build; then
  # The historical tree's own build: swift build -c release + ad-hoc codesign.
  GLIDESLOPE_BUILD_CONFIGURATION=release \
  GLIDESLOPE_UPDATE_CHANNEL="$RELEASE_CHANNEL" \
    "$SOURCE_DIR/script/build_and_run.sh" --build
fi
verify_source_tree
if ! is_clean_release_build; then
  echo "Bridge app is not a clean release build of $BRIDGE_SOURCE_COMMIT." >&2
  exit 1
fi
if [[ "$(plist CFBundleIdentifier)" != "com.owlandkestrel.glideslope" \
  || "$(plist CFBundleShortVersionString)" != "$PINNED_VERSION" || "$(plist CFBundleVersion)" != "$PINNED_BUILD" \
  || "$(plist GlideslopeUpdateChannel)" != "$RELEASE_CHANNEL" || "$(plist SUFeedURL)" != "$LEGACY_FEED_URL" ]]; then
  echo "Bridge app identity, version, channel or feed does not match the admitted bridge." >&2
  exit 1
fi
MIN_SYSTEM_VERSION="$(plist LSMinimumSystemVersion)"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BUNDLE/Contents/MacOS/$LEGACY_APP_NAME")"
SPARKLE_PUBLIC_KEY="$(plist SUPublicEDKey)"
PUBLISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

rm -rf "$BRIDGE_DIR"
mkdir -p "$BRIDGE_DIR"

# Never re-sign: the historical build already sealed the bundle.
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
ZIP_SIZE_BYTES="$(stat -f%z "$ZIP_PATH")"
ARTIFACT_URL="$UPDATE_ORIGIN/glideslope/releases/v$PINNED_VERSION/$ZIP_SHA256/$LEGACY_APP_NAME.zip"
ARTIFACT_URL_PREFIX="${ARTIFACT_URL%/*}/"
printf '%s  %s\n' "$ZIP_SHA256" "$(basename "$ZIP_PATH")" > "$CHECKSUM_PATH"

cat > "$NOTES_PATH" <<'NOTES'
# Glideslope is now Alight

Glideslope has been renamed Alight. This update shows a one-time notice with a
**Download Alight** button; install Alight from that page to keep getting
improvements. Your settings can be brought across when you open Alight.
NOTES

"$SPARKLE_GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$ARTIFACT_URL_PREFIX" \
  --link "$DOWNLOAD_PAGE_URL" \
  --embed-release-notes \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  --versions "$PINNED_BUILD" \
  -o "$APPCAST_PATH" \
  "$BRIDGE_DIR"

APPCAST_ARTIFACT_URL="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
APPCAST_SIGNATURE="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
APPCAST_BUILD="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="version"])' "$APPCAST_PATH")"
if [[ "$APPCAST_ARTIFACT_URL" != "$ARTIFACT_URL" || "$APPCAST_BUILD" != "$PINNED_BUILD" || -z "$APPCAST_SIGNATURE" ]]; then
  echo "Generated bridge appcast does not match the packaged artifact and build." >&2
  exit 1
fi
"$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$ZIP_PATH" "$APPCAST_SIGNATURE"
"$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$APPCAST_PATH"
APPCAST_SHA256="$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')"

# Provenance in Nest's release-origin manifest contract; the builder refuses
# anything but the pinned clean identity.
ALIGHT_VERSION="$PINNED_VERSION" \
ALIGHT_BUILD_NUMBER="$PINNED_BUILD" \
ALIGHT_MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
ALIGHT_ARCHITECTURES="$ARCHITECTURES" \
ALIGHT_PUBLISHED_AT="$PUBLISHED_AT" \
ALIGHT_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
ALIGHT_RELEASE_NOTES="" \
ALIGHT_ARTIFACT_URL="$ARTIFACT_URL" \
ALIGHT_ARTIFACT_SHA256="$ZIP_SHA256" \
ALIGHT_ARTIFACT_SIZE_BYTES="$ZIP_SIZE_BYTES" \
ALIGHT_APPCAST_URL="$LEGACY_FEED_URL" \
ALIGHT_APPCAST_SHA256="$APPCAST_SHA256" \
ALIGHT_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
ALIGHT_DOWNLOAD_PAGE_URL="$DOWNLOAD_PAGE_URL" \
ALIGHT_SOURCE_COMMIT="$BRIDGE_SOURCE_COMMIT" \
ALIGHT_SOURCE_DIRTY="false" \
ALIGHT_SOURCE_BUILD_CONFIGURATION="release" \
node "$RELEASE_MANIFEST_TOOL" payload bridge > "$PAYLOAD_PATH"

# OK_RELEASE_PRIVATE_KEY_FILE (or the legacy OK_RELEASE_PRIVATE_KEY_PEM) signs;
# neither leaves an unsigned preview.
node "$RELEASE_MANIFEST_TOOL" sign "$PAYLOAD_PATH" "$MANIFEST_PATH"

echo "Bridge source $BRIDGE_SOURCE_COMMIT ($PINNED_VERSION, build $PINNED_BUILD)"
echo "Created $ZIP_PATH"
echo "Wrote $CHECKSUM_PATH"
echo "Wrote $APPCAST_PATH"
echo "Wrote $PAYLOAD_PATH"
echo "Wrote $MANIFEST_PATH"
