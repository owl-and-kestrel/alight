# Alight quota snapshot v1 (`ok.alight.quota-snapshot.v1`)

After every refresh Alight writes a small, documented, versioned JSON export of
what each provider reported. Fieldbook and the O+K desk read it to see quota
pace across pools without touching Alight's internals or any credential. The
reader is Fieldbook's `src/quota/alight-snapshot.mjs` (`checkAlightSnapshot`,
`normalizeAlightQuotaSnapshot`); the contract comes from the Fieldbook governed
writer design r2, §4 and slice A3.

`usage-cache.json` stays private. It holds only last-good readings, rebases
cached windows, clamps usage to 0–100, and mixes in display fields. Never parse
it; read this file.

## Location and write

| | |
|---|---|
| Path | `~/Library/Application Support/Alight/quota-snapshot.v1.json`, beside `usage-cache.json` (design r2 §4.1). Application Support is not synced by iCloud Drive. |
| Permissions | file `0600`, directory `0700` |
| Atomicity | temporary file in the same directory (`O_CREAT \| O_EXCL \| O_NOFOLLOW`), `fsync`, `rename` over the target, `fsync` of the directory. A reader sees the previous or the new complete file. A symlink at the target is replaced, never followed. |
| Durability | the export reports `written` only after the directory `fsync` succeeds. If the directory cannot be opened or synced after the rename, the new file is already in place (a reader may see it) but the write is reported as failed (`WriteError.directoryNotSynced`) and logged; `EINTR` is retried. The next write still uses the next `sequence`, so a value a reader may have seen is never reused |
| Trust | the parent directories are trusted, as the cache's are: the exporter does not defend against an alias to the Application Support folder created by the same user |
| Size | at most 256 KiB (the reader's bound); a few KB in practice |
| Trigger | the end of each `UsageStore.performRefresh` (event-driven, on the existing poll), failures included |
| Development builds | an app without a 40-hex `AlightSourceCommit` in its Info.plist (for example `swift run`) writes nothing, because the reader would refuse the file |

Code: `Sources/Alight/QuotaSnapshotExporter.swift`. Tests:
`Tests/AlightTests/QuotaSnapshotExporterTests.swift`.

## Schema

```
{ schema: 'ok.alight.quota-snapshot.v1',
  producer: { app: 'com.owlandkestrel.alight', version, build, sourceCommit /* 40 hex */ },
  installId /* random per install, not an identity */, sequence /* monotonic per installId */, writtenAt /* UTC */,
  providers: [ {
    provider: 'antigravity' | 'claude' | 'codex',
    status: 'observed' | 'failed' | 'signed_out' | 'refused' | 'deferred', // failures are exported too
    attemptedAt, capturedAt /* the time the provider was actually read; never rebased; null if none */,
    readingSource: 'live' | 'cached', cacheAgeSeconds,
    accountRef /* 64 hex, ok.fieldbook.usage-account.v1 digest (usageAccountRef) or null */,
    endpointRef /* 64 hex Antigravity endpoint fingerprint digest, or null */,
    failure: { code /* closed: auth_required | network | rate_limited | parse_failed | refused | unknown */, needsAuth } | null,
    groups: [ { // provider-reported grouping, verbatim
      providerGroup: { displayName, bucketIds: [..] } | null, // Antigravity groups; null for Claude/Codex
      windows: [ { windowId /* session | week | window_<n>s */, cadence: '5h' | 'weekly' | null,
                   usedPercentRaw /* as reported, NOT clamped; finite, >= 0, no upper bound */, usedPercentPrecision: 'unverified' | 'floor_integer' | 'exact',
                   resetAt | null, resetSource: 'provider' | 'unknown', windowSeconds | null, windowSecondsSource: 'provider' | 'label' | 'unknown',
                   providerBucketId | null, scope: { kind: 'model' | 'group', key, displayName } | null } ] } ] } ] }
```

Every key is always written; an absent value is `null`, never omitted. The
schema is closed: no other key is ever written.

## Rules

- Display-only fields (`pressurePercent`, `expectedRemainingPercent`, `visualStyle`) are never exported.
- A value outside the ranges is refused, never clamped. `usedPercentRaw` has no upper bound: any finite value ≥ 0 is
  valid, and a value above 100 is real data (usage over the limit). A negative or non-finite value is refused: that
  provider is exported as `failed` with `parse_failed`, and the menu still shows its clamped display value.
- Failures are exported too (`failed`, `signed_out`, `refused`, `deferred`). They carry `capturedAt: null` and no
  groups, so they become unknowns in Fieldbook rather than "available".
- `capturedAt` is the time the provider was actually read and is never rebased. A cached reading keeps its original
  capture time: the completion of the provider's own request, not the end of the refresh that cached it, and to the
  millisecond across a relaunch.
- A current attempt that needs sign-in is `signed_out` with `auth_required`, even when the menu is still showing a
  last-good cached reading. The cache never turns a known sign-in failure into an observed reading.
- The export holds no credentials, tokens, cookies, raw HTTP bodies, raw emails or organisation ids; only two
  digests. `accountRef` is domain-separated (Fieldbook's `ok.fieldbook.usage-account.v1` tag). `endpointRef` is
  not: it is the plain sha256 of the Antigravity endpoint URL, the fingerprint Alight's cache already uses; changing
  it would need Fieldbook's agreement. Both are stable pseudonymous identifiers, not authenticated identities.
- Versioning: `schema` carries the major version. Additive optional fields keep v1; a changed meaning, a removed
  field or a growing closed vocabulary is v2. Fieldbook treats any other version as `snapshot_schema_unsupported`,
  a `sequence` regression under one `installId` as `snapshot_sequence_regression`, and a `writtenAt` older than
  900 s as `snapshot_stale` (which also covers Alight not running).

## Field mapping

### Snapshot

| Field | Source |
|---|---|
| `producer.app` | the constant `com.owlandkestrel.alight` |
| `producer.version`, `build`, `sourceCommit` | Info.plist `CFBundleShortVersionString`, `CFBundleVersion`, `AlightSourceCommit` (stamped by `script/build_and_run.sh`) |
| `installId` | a random lowercase UUID. It resumes from Alight's own previous `quota-snapshot.v1.json`; if that file is missing or unreadable, or its `sequence` is not a non-negative safe integer, a new one is drawn, which can never read as a regression of the old one |
| `sequence` | 0 for a new `installId`, then +1 per write, resumed from the previous file across relaunches. Never above `Number.MAX_SAFE_INTEGER` (2^53 − 1), the reader's bound: the write after that value starts a new `installId` at 0 |
| `writtenAt` | wall clock at the write, UTC with milliseconds |
| `providers` | one entry per provider per refresh, sorted `antigravity`, `claude`, `codex` |

### Provider

| Field | Source |
|---|---|
| `status` | `observed` when the refresh produced windows with exportable facts and the current attempt does not need sign-in; otherwise `deferred` (Claude not due; source `deferred`), `refused` (Claude Code answered `/usage` with a model turn), `signed_out` (the current attempt needs sign-in: missing or expired credentials, HTTP 401, `claude auth status` signed out; also when a cached reading is being shown), else `failed` |
| `attemptedAt` | the start of the refresh |
| `capturedAt` | live: the completion time of that provider's request. Cached: that same original time, kept by the cache at full precision (older caches: whole seconds). `null` when not observed |
| `readingSource` | `cached` when the menu is showing a last-good reading after a failed or deferred poll; otherwise `live` (for a failure: no reading was substituted) |
| `cacheAgeSeconds` | for a cached reading, its age at the end of this refresh, measured from the original `capturedAt`; for a failure with a cached reading (expired, or not exported because sign-in is needed), that reading's age; else `null` |
| `accountRef` | Fieldbook `usageAccountRef`: sha256 of the JSON array `['ok.fieldbook.usage-account.v1', provider, identifierKind, organization.trim(), identifier]`, with JavaScript's `trim()` and `toLowerCase()` ported exactly (ECMAScript whitespace: U+FEFF is trimmed, U+0085 is not; final sigma; no Unicode normalization on either side). An email containing a code point Alight's Unicode tables do not assign gives `null` rather than risk a digest Fieldbook would compute differently. Claude: `identifierKind 'email'`, the email (trimmed, lowercased) and `orgId` from `claude auth status --json`. Codex: `'opaque'`, the `account_id` sent with the request, organization `''`. Antigravity: `null` (no account identity is read). A cached Codex reading is `null`, because the cache does not bind Codex readings to an account |
| `endpointRef` | Antigravity only: plain sha256 of the usage endpoint URL (not domain-separated), the same fingerprint the cache binds Antigravity readings to. `null` for Claude and Codex |
| `failure` | `null` when observed. `signed_out`: `{auth_required, needsAuth: true}`. `refused`: `{refused, false}`. `deferred`: `null`, or `{auth_required, true}` when the last attempt needed sign-in. `failed`: the client's code (below), `unknown` when it has none |

Failure codes per client:

| Client | `auth_required` | `network` | `rate_limited` | `parse_failed` | `refused` |
|---|---|---|---|---|---|
| Codex | no token in `auth.json` | `URLError` | — | undecodable payload; no windows | — |
| Claude | signed out; sign-in text | — | — | unexpected `/usage` output, unknown limit line | model turn |
| Antigravity | not signed in, token expired, HTTP 401 | no HTTP response, `URLError` | HTTP 429 | malformed payload, incomplete broad windows | — |

Other failures (a CLI that will not start or times out, other HTTP statuses) are `unknown`. An observed reading whose
facts cannot be exported (a refused raw value, or a reading cached by an Alight version without the exporter) is
`failed` with `parse_failed`.

### Groups and windows

Each parser records the provider's own facts beside the display windows (`QuotaReport` in
`QuotaSnapshotExporter.swift`). The display path keeps its clamping and defaults; the export never sees them.

| Field | Claude (`/usage` text) | Codex (`wham/usage`) | Antigravity (`retrieveUserQuotaSummary`) |
|---|---|---|---|
| groups | one, `providerGroup: null` | one, `providerGroup: null` | one per reported group, in order, every group including non-Gemini ones (design A-1); `displayName` verbatim, `bucketIds` every bucket's id |
| `windowId`, `cadence` | from `windowSeconds`: 18000 → `session`/`5h`, 604800 → `week`/`weekly`, else `window_<n>s`/`null` | same | same |
| `windowSeconds`, source | `Current session` 18000, `Current week …` 604800; `label` | `limit_window_seconds`; `provider` | the bucket's `window` (`5h`, `weekly`), else its id suffix (`-5h`, `-weekly`); `label`. Missing or conflicting evidence refuses the reading |
| `usedPercentRaw` | the printed figure (`100 − n` for `n% left`), unclamped | `used_percent`, unclamped | `(1 − remainingFraction) × 100`, unclamped, rounded to 6 decimals (as Fieldbook's direct reader) to drop binary noise; a missing fraction refuses the reading |
| `usedPercentPrecision` | `floor_integer` for a whole `n% used` (Claude Code prints `floor(utilization)`), else `unverified` | `unverified` | `unverified` |
| `resetAt`, `resetSource` | the printed reset, `provider`; `null`/`unknown` when Claude Code printed none (an unused window). A printed reset that has already passed is exported as printed | `reset_at`, `provider` | `resetTime`, `provider`; `null`/`unknown` when absent; an unparseable value refuses the reading |
| `providerBucketId` | `null` | `primary_window` or `secondary_window` | the bucket's `bucketId` |
| `scope` | `null` for the session and all-models week; `{model, <key>, <name>}` for a model week (`fable`/`Fable`) | `null` | `null` (the group is the scope; Fieldbook maps groups to pools) |

A cached reading exports the facts stored with it, minus windows whose reported reset has passed (the display drops
the same windows), unless the current attempt needs sign-in (then `signed_out`, above).

Before writing, the exporter checks each provider against the reader: closed vocabularies, non-blank text (blank
after JavaScript `trim()`, as Fieldbook tests it), a whole
positive `windowSeconds`, a whole number under `floor_integer`, at least one window, and unique reader window keys
(`windowId`, plus the Fieldbook group slug for a non-Gemini Antigravity group or the scope key for Claude). A provider
that fails is exported as `failed`/`parse_failed`, so one bad provider cannot make Fieldbook refuse the whole file.

## Example

```json
{
  "installId" : "3c1f6a0e-6a7e-4b7e-9d55-0f3b1e2a9c41",
  "producer" : { "app" : "com.owlandkestrel.alight", "build" : "42", "sourceCommit" : "<40 hex>", "version" : "1.3.3" },
  "providers" : [
    { "accountRef" : null, "attemptedAt" : "2027-01-15T08:00:00.000Z", "cacheAgeSeconds" : null,
      "capturedAt" : "2027-01-15T08:00:02.000Z", "endpointRef" : "<64 hex>", "failure" : null,
      "groups" : [
        { "providerGroup" : { "bucketIds" : [ "gemini-5h", "gemini-weekly" ], "displayName" : "Gemini Models" },
          "windows" : [ { "cadence" : "5h", "providerBucketId" : "gemini-5h", "resetAt" : "2027-01-15T09:00:00.000Z",
                          "resetSource" : "provider", "scope" : null, "usedPercentPrecision" : "unverified",
                          "usedPercentRaw" : 25, "windowId" : "session", "windowSeconds" : 18000,
                          "windowSecondsSource" : "label" } ] },
        { "providerGroup" : { "bucketIds" : [ "3p-weekly" ], "displayName" : "Claude and GPT models" },
          "windows" : [ { "cadence" : "weekly", "providerBucketId" : "3p-weekly", "resetAt" : "2027-01-20T10:00:00.000Z",
                          "resetSource" : "provider", "scope" : null, "usedPercentPrecision" : "unverified",
                          "usedPercentRaw" : 125, "windowId" : "week", "windowSeconds" : 604800,
                          "windowSecondsSource" : "label" } ] } ],
      "provider" : "antigravity", "readingSource" : "live", "status" : "observed" },
    { "accountRef" : null, "attemptedAt" : "2027-01-15T08:00:00.000Z", "cacheAgeSeconds" : null,
      "capturedAt" : null, "endpointRef" : null, "failure" : { "code" : "auth_required", "needsAuth" : true },
      "groups" : [ ], "provider" : "claude", "readingSource" : "live", "status" : "signed_out" }
  ],
  "schema" : "ok.alight.quota-snapshot.v1",
  "sequence" : 7,
  "writtenAt" : "2027-01-15T08:00:03.000Z"
}
```

## Verifying against Fieldbook

The tests write sample snapshots when `ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR` names a directory:

```sh
mkdir -p /tmp/alight-fixtures
ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR=/tmp/alight-fixtures \
  script/test_swift.sh --skip liveFetchIfCredentialsExist --filter QuotaSnapshot
```

The filter selects both suites (`QuotaSnapshotExporterTests`, `QuotaSnapshotContractRegressionTests`); the explicit
`--skip` keeps the run offline even if the filter is widened. Then run Fieldbook's `checkAlightSnapshot` and
`normalizeAlightQuotaSnapshot` on each `.json` file (a `readAt` within 900 s of its `writtenAt`); both must accept it.
A cached sample must keep the live capture time, and a `signedout-cached-*` sample must normalize to an unknown with
`alight:signed_out:auth_required`. `digests.vectors` lists each Unicode test vector with Alight's digest; each must
equal Fieldbook's `usageAccountRef` for the same input.
