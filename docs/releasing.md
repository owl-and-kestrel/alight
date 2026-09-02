# Glideslope Release Channel

Glideslope uses Sparkle as its executable update authority and an O+K-owned
HTTPS release origin as its stable distribution boundary. Plumage, O+K
Release/Trust, and Chirp may describe or announce a release, but none is in the
installed app's update-fetch or verification path.

Current release identity:

- app version: `0.4.1`
- build: `9`
- bundle identifier: `com.owlandkestrel.glideslope`
- update channel: `stable`
- Sparkle: exact version `2.9.4`
- feed: `https://updates.owlandkestrel.com/glideslope/stable/appcast.xml`
- storage authority: Nest release origin on Spruce

`package.json` is the version and monotonic-build authority. Release bundle
generation embeds both values, the stable feed URL, and the Sparkle public key
in `Info.plist`.

## Distribution Boundary

The public object layout is:

```text
glideslope/
    ├── stable/
    │   └── appcast.xml
    └── releases/
        └── v<version>/
            └── <sha256>/
                └── Glideslope.zip
```

Release archives are content-addressed and immutable. Never replace the bytes
at an existing release URL. `stable/appcast.xml` is the one mutable channel
pointer and is published only after its referenced archive is publicly readable
and verified.

Migration state as of 2026-08-20:

- the complete 18-object R2 inventory is imported into the O+K-owned Spruce
  origin and reconciled without hidden or orphaned keys;
- the unchanged hostname, all release bytes, Sparkle signatures, GET, HEAD,
  range responses, cache policy, and MIME types pass direct-origin replay;
- direct R2 publication is retired and channel advancement is frozen until the
  authenticated Nest release-origin client replaces it;
- Chirp channel `glideslope-updates` exists and is active. Initialization
  record: `msg_2dbcb564d6a24859bebe0323be04a343`.
- Stable `0.4.1` build `9` is recorded in the O+K release ledger as publication
  `rpub_6b174f80-1c62-4f01-bdfa-84d9c88541d5`; its release announcement is
  Chirp record `evt_c786b4c9a7f044408f7e037283132c32`. The immutable archive
  SHA-256 is `57071931c935733b67e864360fc36b57fd3ad805774257b77545c4feb9a80aee`.
  An identical retry replays the existing receipts rather than creating a
  second publication or announcement.
- Stable `0.5.0` build `10` adds Antigravity usage tracking with purple hands;
  its immutable archive SHA-256 is `6ba9ae2324c588f92735d2d11a6b40231cebb92b5227a283227056bfca3285fc`,
  published on Spruce via `FileReleaseOrigin` under pointer CAS operation
  `6af25941e0b960fab32ce8251d2629a313cab1bbc3c0a57890ed46575dd6b73c`.

## Sparkle Trust Authority

Sparkle's Ed25519 key is the installed app's update identity. The public key is
committed at:

```text
config/sparkle-ed25519.pub
```

The private key's canonical copy is a macOS Keychain generic-password item with:

```text
service: https://sparkle-project.org
account: owl-kestrel
```

The noninteractive packager reads a mode-`0600` export at:

```text
~/.config/owl-kestrel/secrets/sparkle-ed25519-private-key
```

Create or refresh that export without displaying the secret:

```sh
install -d -m 700 ~/.config/owl-kestrel/secrets
umask 077
key_export="$(mktemp -t glideslope-sparkle-key)"
trap 'rm -f "$key_export"' EXIT
security find-generic-password \
  -s https://sparkle-project.org \
  -a owl-kestrel \
  -w > "$key_export"
install -m 600 "$key_export" \
  ~/.config/owl-kestrel/secrets/sparkle-ed25519-private-key
```

Never print, commit, upload, paste, or include the private key in an app bundle,
release archive, manifest, log, or shell trace. Keep the Keychain item as the
canonical copy; the file is a local packaging export only.

The Sparkle Ed25519 authority is independent of the O+K P-256 provenance key at
`config/ok-release-p256-v1.pub.pem`. Sparkle verifies the signed appcast and
archive before installation. O+K Trust may additionally carry a signed
`ok.product-update.v1` envelope through the typed release ledger, but that
envelope is secondary provenance and cannot authorize executable replacement.

## Installed-App Behavior

Release builds default to automatic update checks, downloads, and installation.
They embed these relevant Sparkle fields:

```text
SUFeedURL=https://updates.owlandkestrel.com/glideslope/stable/appcast.xml
SUPublicEDKey=<contents of config/sparkle-ed25519.pub>
SUEnableAutomaticChecks=true
SUAutomaticallyUpdate=true
SUAllowsAutomaticUpdates=true
SUScheduledCheckInterval=86400
SUVerifyUpdateBeforeExtraction=true
SURequireSignedFeed=true
SUSignedFeedFailureExpirationInterval=0
```

The menu item **Install Updates Automatically** is an installation opt-out. It
changes Sparkle's automatic-download/install preference but deliberately leaves
scheduled checks enabled, so manual-install users still learn that a release is
available. **Check for Updates…** always performs an explicit Sparkle check.

Debug builds embed `SUEnableAutomaticChecks=false` and
`SUAutomaticallyUpdate=false`. They may check explicitly, but must not replace
themselves from the public stable channel in the background.

Update requests go only to the public HTTPS feed and archive URLs. They do not
contain Codex or Claude credentials, usage readings, an O+K account, a Chirp
credential, or a Plumage session.

## Technical-Alpha Installation And Apple Transition

The current technical alpha is ad-hoc signed, not Developer ID signed or
notarized. A first browser-downloaded installation may therefore be blocked by
Gatekeeper. The user must make the one-time macOS override through **System
Settings → Privacy & Security → Open Anyway**.

Versions installed before Sparkle was embedded cannot be pulled forward by the
new updater. Those users need one manual bridge installation of the first
Sparkle-enabled release. After that, the pinned Ed25519 key and stable feed can
carry them forward automatically.

When an Apple Developer account becomes available, keep all of these stable:

- bundle identifier `com.owlandkestrel.glideslope`
- `SUFeedURL`
- Sparkle Ed25519 key

Add Developer ID signing and notarization to a later archive delivered through
this same channel. Do not rotate the Sparkle Ed25519 key in the same release that
introduces Developer ID: changing both trust anchors at once makes diagnosis and
recovery unnecessarily ambiguous. If the Sparkle key ever needs planned
rotation, first ship an update authorized by the old key that embeds the new
public key.

## Prepare A Release

Start from a clean intended commit and run the full verification:

```sh
npm test
npm run test:swift
npm run build:native
```

Set release notes and package the current version:

```sh
GLIDESLOPE_RELEASE_NOTES="Describe the user-visible changes." \
  npm run package:release
```

The packager creates a release build, verifies its source provenance and
ad-hoc signature, signs the archive and appcast with Sparkle's Ed25519 key, and
then verifies both signatures. Expected outputs:

```text
dist/release/Glideslope.zip
dist/release/Glideslope.zip.sha256
dist/release/appcast.xml
dist/release/Glideslope.md
dist/release/glideslope-update.payload.json
dist/release/glideslope-update.json
dist/release/RELEASE_NOTES.txt
```

When `OK_RELEASE_PRIVATE_KEY_PEM` is set, packaging also wraps the provenance
payload as `ok.signed-manifest.v1` using the canonical O+K signer. Without it,
the provenance manifest is an unsigned local preview; that does not weaken the
separate Sparkle signature, but stable Trust publication should still require
the O+K provenance signature.

## Publish The Release

The publisher owns the entire transaction. First inspect its secret-free,
mutation-free plan:

```sh
npm run release:dry-run
```

Routine publication is intentionally frozen during the owned-origin cutover.
`release:publish` fails closed before credential lookup or any remote write.
It will be restored only when the authenticated Nest client owns the complete
archive-first/pointer-last transaction:

```sh
npm run release:publish  # expected to fail closed while frozen
```

The dry-run still validates the manifest, exact appcast shape,
content-addressed URL, ZIP length and SHA-256, and provenance signature. The
future Nest transaction must additionally verify both Sparkle signatures,
monotonic live build, exact pointer predecessor, immutable archive readback,
appcast readback, Release/Trust receipt, and Chirp deduplication before it can
replace the freeze.

### Recovery procedure

There is no direct-storage recovery command. Restore or republish only through
Nest's receipt-bound operation and exact pointer CAS. Until that client is
installed, the current `0.4.1` build `9` feed remains fixed and no new release
is authorized. Do not use Wrangler, raw filesystem mutation, or an R2 fallback
to advance the channel.

## Publication Ordering And Secondary Signals

The complete order is an invariant:

1. Stage and commit the immutable archive through Nest.
2. Read it back and verify SHA-256.
3. Advance `stable/appcast.xml` through exact pointer CAS last.
4. Read it back and verify the signed feed, enclosure URL, and build.
5. Publish the signed envelope to O+K's append-only Release/Trust ledger.
6. Emit the deduplicated `product.release_available` event to Chirp channel
   `glideslope-updates`.

Release/Trust is useful provenance and catalog metadata, but it is not the
updater's source of truth. Moving auth into Plumage must not change or proxy the
feed hostname. Installed apps never poll Chirp; Chirp remains publisher-side
fan-out for humans and operators.

The restored publisher must validate package version, build metadata, app and
bundle ids, channel, exact source commit, clean/dirty provenance, archive
SHA-256, appcast SHA-256 and enclosure metadata, both Sparkle signatures, and
the O+K P-256 envelope before any remote write. Stable publication must refuse
a dirty source or unsigned provenance envelope. Chirp's dedupe key includes
channel, version, build, and artifact digest, so retrying after an announcement
failure remains safe.

## Release And Rollback Checklist

Before publication:

- Confirm version `0.4.1`, build `9`, source commit, and intended clean tree.
- Confirm `codesign --verify --deep --strict dist/Glideslope.app` succeeds.
- Confirm the packaged feed and archive signatures verify.
- Install the ZIP on a separate Mac and test launch, usage-cache recovery,
  **Check for Updates…**, and the automatic-install opt-out.
- Complete the archive-first/appcast-last Nest readback sequence.
- Run `release:dry-run` and review both secondary payloads.

After publication:

- Check from the previous Sparkle-enabled version and confirm automatic update.
- Confirm opting out of **Install Updates Automatically** preserves scheduled
  update checks.
- Read the Release/Trust channel and confirm version, artifact URL, and digest.
- Read `glideslope-updates` and confirm exactly one release event.

If a release must be withdrawn, remove or replace the mutable appcast entry and
revoke/unpublish its Trust projection. Keep the append-only release publication
as historical evidence. Do not point the same immutable URL or version
at different bytes. Publish corrected bytes under a higher build/version and a
new content-addressed URL; installed clients must never be asked to accept a
rollback.
