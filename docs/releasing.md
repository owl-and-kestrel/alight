# Alight Release Channel

Alight uses Sparkle as its executable update authority and an O+K-owned
HTTPS release origin as its stable distribution boundary. Plumage, O+K
Release/Trust, and Chirp may describe or announce a release, but none is in the
installed app's update-fetch or verification path.

Current release identity:

- app version: `0.6.0`
- build: `13`
- product/app id: `alight`
- bundle identifier: `com.owlandkestrel.alight`
- update channel: `stable`
- Sparkle: exact version `2.9.4`
- feed: `https://updates.owlandkestrel.com/alight/stable/appcast.xml`
- storage authority: Nest release origin on Spruce

This source rename is prepared for a coordinated remote cutover. The current
Nest project, release ledger records, and installed applications still use the
historical `glideslope` identity until the owner executes the cutover. Nest
source is currently `ssh://git@5.161.252.182/srv/git/glideslope.git`; the target
source remote is `ssh://git@5.161.252.182/srv/git/alight.git`. Nest must create
or rename the project identity to `alight`, register the new app id and bundle
id, and grant the release-origin operation access before any Alight
publication. This repository does not change Nest state, credentials, or the
existing feed.

`package.json` is the version and monotonic-build authority. Release bundle
generation embeds both values, the stable feed URL, and the Sparkle public key
in `Info.plist`.

## Distribution Boundary

The public object layout is:

```text
alight/
    ├── stable/
    │   └── appcast.xml
    └── releases/
        └── v<version>/
            └── <sha256>/
                └── Alight.zip
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
- Historical Chirp channel `glideslope-updates` exists and is active. Initialization
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

Historical Glideslope release objects remain immutable under the old
`/glideslope/` prefix. Their receipt ids, archive bytes, Sparkle signatures,
and the old `com.owlandkestrel.glideslope` identity are evidence for the prior
product and must not be rewritten. The established Sparkle trust key id
`sparkle-glideslope-1` and its key bytes remain unchanged. The first Alight archive uses the new
`/alight/` prefix and receives a new publication receipt after Nest validates
the rename. The Sparkle Ed25519 key and O+K provenance key remain unchanged.

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
key_export="$(mktemp -t alight-sparkle-key)"
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
SUFeedURL=https://updates.owlandkestrel.com/alight/stable/appcast.xml
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

### Rename cutover and local data

Installed Glideslope apps are carried across by a **bridge release on the
historical Glideslope feed**, produced by `script/package_bridge.sh` (run
automatically by `package_release.sh`, skip with `ALIGHT_SKIP_BRIDGE=1`).
Sparkle installs an update into the host's existing path and locates the app
inside the archive by the host's file name, falling back to the host's bundle
identifier (`Autoupdate/SUInstaller.m` in the pinned 2.9.4 checkout). It does
not compare the incoming app's bundle identifier with the host's; the
"Failed to match host bundle identifiers" check in `AppInstaller.m` compares
the running host with itself. An archive containing only `Alight.app` is
therefore invisible to a `Glideslope.app` host, while an archive containing
the identical Alight build named `Glideslope.app` installs cleanly. The bridge
outputs are:

```text
dist/release/bridge/Glideslope.zip        # release Alight.app, renamed
dist/release/bridge/Glideslope.zip.sha256
dist/release/bridge/appcast.xml           # signed, for /glideslope/stable/
dist/release/bridge/glideslope-bridge.json
```

The bridge archive is the same bytes as the release build (verified with
`codesign --verify --deep --strict` after the rename; the ad-hoc seal covers
bundle contents, not the folder name) and is signed with the same Sparkle
Ed25519 key the old apps already trust. Its content-addressed URL is
`/glideslope/releases/v<version>/<sha256>/Glideslope.zip`, and its appcast
advances `/glideslope/stable/appcast.xml` last, exactly like the Alight
channel. Publish the Alight release first, then the bridge, so a bridged app's
first check against the Alight feed finds a matching build.

After Sparkle relaunches the bridged app it is Alight (bundle
`com.owlandkestrel.alight`, `SUFeedURL` on the Alight feed) still living at
`…/Glideslope.app`. On launch `BridgeRelocation` renames the bundle to
`Alight.app` beside it when that name is free and the directory is writable,
then relaunches from the new path. If the rename is not possible the app keeps
running from the old name; later Alight archives still match it by bundle
identifier. Login items are bookmark-based and follow the rename.

On its first launch, Alight shows a one-time notice when it finds legacy
non-secret state. Choose **Import Settings** to copy the valid native cache and
allowlisted appearance settings before the status item starts, or choose
**Start Fresh**. The destination is never overwritten and the old cache/domain
remains as recovery evidence. For command-line state, quit Alight and run
`npm run migrate:data`; that command previews by default and requires `--apply`
to copy valid CLI state. UserDefaults settings are migrated only by the native
Import Settings choice, which applies an allowlist before launch. Choosing
**Later** leaves the prompt available on the next launch.

Dedicated token files are user-managed credentials. The migration command never
reads or copies token bytes; it reports the old and new paths so the owner can
copy them with mode `0600` during the reviewed cutover. Shared Claude and Gemini
Keychain items retain their provider-owned identities and are read only. Remove
the migration command and the bridge packaging after one completed Alight
release cycle and verified user migration.

The bridge was exercised locally on 2026-09-22: a copy of the installed
Glideslope 0.5.1 (build 11) with its feed pointed at a loopback server carrying
the bridge appcast downloaded, verified, and installed the Alight 0.6.0 build in
place through Sparkle's normal automatic-update path.

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

- bundle identifier `com.owlandkestrel.alight`
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
ALIGHT_RELEASE_NOTES="Describe the user-visible changes." \
  npm run package:release
```

The packager creates a release build, verifies its source provenance and
ad-hoc signature, signs the archive and appcast with Sparkle's Ed25519 key, and
then verifies both signatures. Expected outputs:

```text
dist/release/Alight.zip
dist/release/Alight.zip.sha256
dist/release/appcast.xml
dist/release/Alight.md
dist/release/alight-update.payload.json
dist/release/alight-update.json
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
installed, the historical Glideslope feed remains fixed and no new release
is authorized. Do not use Wrangler, raw filesystem mutation, or an R2 fallback
to advance the channel.

## Publication Ordering And Secondary Signals

The complete order is an invariant:

1. Register the Alight project/app/bundle identity in Nest and reconcile the
   reviewed source repository and branch.
2. Stage and commit the immutable archive through Nest.
3. Read it back and verify SHA-256.
4. Advance `stable/appcast.xml` through exact pointer CAS last.
5. Read it back and verify the signed feed, enclosure URL, and build.
6. Publish the signed envelope to O+K's append-only Release/Trust ledger.
7. Emit the deduplicated `product.release_available` event to the registered
   Alight Chirp channel.

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

- Confirm version `0.6.0`, build `13`, source commit, and intended clean tree.
- Confirm `dist/release/bridge/` exists and its `glideslope-bridge.json` names
  the same version and build as the Alight manifest.
- Confirm `codesign --verify --deep --strict dist/Alight.app` succeeds.
- Confirm the packaged feed and archive signatures verify.
- Install the ZIP on a separate Mac and test launch, usage-cache recovery,
  **Check for Updates…**, and the automatic-install opt-out.
- Complete the archive-first/appcast-last Nest readback sequence.
- Run `release:dry-run` and review both secondary payloads.

After publication:

- Check from an installed Glideslope app and confirm it updates to Alight,
  renames itself to `Alight.app`, and then checks the Alight feed.
- Check from an installed Alight app and confirm automatic update.
- Confirm opting out of **Install Updates Automatically** preserves scheduled
  update checks.
- Read the Release/Trust channel and confirm version, artifact URL, and digest.
- Read `alight-updates` and confirm exactly one release event.

If a release must be withdrawn, remove or replace the mutable appcast entry and
revoke/unpublish its Trust projection. Keep the append-only release publication
as historical evidence. Do not point the same immutable URL or version
at different bytes. Publish corrected bytes under a higher build/version and a
new content-addressed URL; installed clients must never be asked to accept a
rollback.
