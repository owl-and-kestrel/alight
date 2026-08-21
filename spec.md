# Glideslope Spec

Glideslope is a tiny macOS menu bar gauge for coding-agent usage-window pressure. It tracks **Codex** and **Claude Code** together.

## Purpose

Both Codex and Claude Code expose usage remaining, but the signal is buried and raw percentages are hard to interpret. Glideslope turns each provider's current usage window into a pace reading: whether remaining usage is lower than, equal to, or higher than expected for this point in the window.

The goal is one calm glance, not another dashboard.

## Providers

Glideslope tracks two providers. Each contributes the windows its usage API currently reports; a provider may expose only one cadence:

- **Codex** — teal hands.
- **Claude Code** — coral hands.

Providers are polled independently; one being unavailable never blocks the other.

## Core Model

For each usage window:

```text
actual_remaining = 1 - used_fraction
expected_remaining = time_until_reset / window_duration
pressure = actual_remaining - expected_remaining
```

Interpretation:

- `low`: remaining usage is below the expected line
- `even`: remaining usage is close to the expected line
- `high`: remaining usage is above the expected line

Default thresholds:

```text
low   pressure < -5 percentage points
even  -5 <= pressure <= +5 percentage points
high  pressure > +5 percentage points
```

## Display

The tooltip/summary names the most constrained window across all providers: the window with the lowest pressure (e.g. `Claude 5h -8% low`).

The native icon is the focus, and the hands are the focus of the icon — the most dominant element. The dial is a dark circle with a fine dotted scale (small white dots) on a square canvas so it never crops; the hands are large and vivid against the dark face. The only colored scale element is a solid bright-red redline arc on the hot end. The hands carry the identity:

- **Provider → hand color.** Codex teal, Claude coral.
- **Window → radial band.** Both hands are bold lines. The long (weekly) window is a long line from a short tail through the hub out past the tick marks; the short (~5h) window is a short line in the outer band, from the edge inward past the ticks (an emphasized tick). The two bands keep the hands from swallowing each other when their angles align.
- **Pressure → depth.** The most-constrained (highest-pressure) window draws last, so the hand that matters most sits in the foreground.
- Each hand has only a thin dark edge (kept minimal so the bright fill dominates).
- The redline marks the consumed-past-pace danger end; a hand swinging into it is the only color cue you need.
- The icon exposes local slider settings for Fable star size/radius, short-window hand
  length/width/radius, weekly hand length/width/radius, scale dot size/radius,
  redline width, and hub dot size. Provider colors and redline color use swatch
  menus. Settings are stored in `UserDefaults` and redraw the menu-bar icon
  immediately. Geometry sliders are intentionally broad and do not apply hidden
  renderer clamps; elements may move off the dial and are bounded only by the
  icon canvas.
- The unused bottom arc contains open reset-clock hands for active broad limits,
  without a separate face or rim. Each hand completes one clockwise revolution
  per limit window and returns to 12 at reset. Seven ticks on the inner weekly
  track divide it into one-day intervals; five ticks on the outer 5h track
  divide it into one-hour intervals. Hands stop just inside their matching
  track, and absent limit kinds do not create hands or tick tracks. Scoped
  markers remain off the reset clock. The complete time layer draws beneath
  quota hands and scoped markers. The menu shows each limit's local reset time
  and compact countdown.

Each hand uses a pace-relative consumption scale: pegged left = `0%` consumed, centered = exactly on the expected reset pace, pegged right = `100%` consumed / `0%` remaining. Usage from `0%` to on-track maps across the left half; on-track to exhausted maps across the right half.

When a provider has no data its hands are simply omitted; the gauge degrades to whatever providers are available.

When a provider needs credentials (not signed in, or token expired/rejected), the dropdown surfaces a **Sign in to …** action that launches that CLI's login in Terminal (`codex login` / `claude auth login`).

The dropdown groups windows under each provider:

```text
● Codex
    5h: 98% left, +4 good
    Weekly: 94% left, +2 good
● Claude
    5h: 71% left, -8% low
    Weekly: 88% left, +1 good
```

Percentages are shown as percentage points of pressure unless otherwise labeled.

## Data Sources

### Codex

- Read Codex auth from `~/.codex/auth.json`
- Call `https://chatgpt.com/backend-api/wham/usage`
- Read `rate_limit.primary_window` and `rate_limit.secondary_window` as transport slots, then classify each from its authoritative `limit_window_seconds`; do not assume `primary_window` means 5h
- Expected fields: `used_percent`, `reset_at`, `limit_window_seconds`

### Claude Code

- Resolve the OAuth access token in precedence order: (1) `CLAUDE_CODE_OAUTH_TOKEN` env, (2) token file `~/.glideslope/claude-token` (override `GLIDESLOPE_CLAUDE_TOKEN_FILE`) — the reliable channel for a GUI/login-item app that doesn't inherit the shell env, (3) the `Claude Code-credentials` Keychain item via `security find-generic-password -s … -w` (mirrors Astra's `providers/cli.py`; shelling out avoids the ACL failure an unsigned app hits through the Security framework). For an always-live hand, `claude setup-token` mints a long-lived token for the env/file path.
- Call Anthropic's subscription usage endpoint (`https://api.anthropic.com/api/oauth/usage`, overridable via `GLIDESLOPE_CLAUDE_USAGE_URL`) with `Authorization: Bearer …`.
- Map `five_hour` → fast and `seven_day` → slow. Each window carries `utilization` (0–100 percent) and `resets_at` (ISO-8601); the decoder tolerates a few alternate field names but is pinned to this shape.
- The response also includes a `limits` array with richer session/weekly/scoped
  entries. A 2026-07-04 live payload showed active `weekly_scoped` usage for
  model `Fable`; Glideslope renders that scoped limit as a four-pointed star on
  the dial's outer edge and as a Claude dropdown row while the latest fresh
  successful response includes it.
  Model-specific top-level buckets such as `seven_day_sonnet` and
  `seven_day_opus` were present but `null`, so scoped usage should come from
  `limits[]`, not from one-off top-level bucket fields.
  Every other active `weekly_scoped` model entry parses into a dropdown-only
  row with its own reset time and countdown; it draws nothing on the dial, so
  no active scoped usage is silently hidden. Duplicate scope identities keep
  the first payload occurrence, and entries without a model identity are
  skipped rather than guessed.
- **Read-only.** Glideslope never refreshes or rewrites the Keychain item, so it cannot invalidate the refresh token the Claude Code app depends on. An expired access token degrades to `token expired — open Claude Code to refresh`.
- **Gentle polling.** The usage endpoint rate-limits aggressively, so Claude is polled on a five-minute cadence with exponential backoff on failure, decoupled from Codex's 60s loop. Manual Refresh forces a live Claude attempt. HTTP `429` responses use Anthropic's `Retry-After` header instead of the generic backoff, and scheduled/manual refreshes share one in-flight task.

### Native last-known cache

- Persist derived usage windows and capture timestamps at
  `~/Library/Application Support/Glideslope/usage-cache.json` with mode `0600`.
- Never persist tokens, credential blobs, account ids, or raw provider responses.
- A live failure does not erase still-valid last-known hands. The dropdown shows
  cache age, current error, and the auth action together.
- Recompute cached pressure against the current clock on every refresh.
- Retire each cached hand at its own reset timestamp instead of using an
  arbitrary provider-wide TTL.
- Claude Desktop private history/cookies are not a fallback source. Its sampled
  history can omit reset times, and its web session is not a supported third-
  party credential surface.

Fallback sources (Codex):

- Cached last-good response at `~/.codex-usage-pressure/state.json`
- Manual state written by the local CLI

Automatic sources are intentionally primary. Manual input exists only as a resilience path.

## Safety

- Never print or cache any provider auth token.
- Never write back to the Claude Code Keychain item (read-only credential access).
- Cache only derived usage windows and freshness metadata.
- Treat endpoint failures as degraded telemetry, not as zero usage.
- Prefer reset-bounded, stale-but-labeled data over a scary blank state.
- Show credential failures and cached hands together; never disguise cached data
  as a live success.
- Retry credential failures quickly so a refreshed Claude Code Keychain item is
  picked up without waiting for the generic network backoff.

## Non-Goals

- No in-Codex / in-Claude UI injection.
- No OCR or settings-screen scraping as the normal path.
- No autonomous usage throttling.
- No account sharing, credential export, or third-party service sync.
- No direct Claude Desktop cookie, Chromium-store, or private endpoint access.
- No update installation that bypasses Sparkle's signed-feed and signed-archive
  verification.

## Release Update Channel

- `package.json` is the version and monotonic-build authority. The current
  release identity is version `0.4.0`, build `8`, and bundle identifier
  `com.owlandkestrel.glideslope`.
- The native app embeds exact Sparkle version `2.9.4`. Its executable update
  authority is the Ed25519 public key committed at
  `config/sparkle-ed25519.pub`; the private key never enters the repo, app, feed,
  archive, or log.
- The stable feed is
  `https://updates.owlandkestrel.com/glideslope/stable/appcast.xml`, served with
  immutable content-addressed archives from dedicated Cloudflare R2 bucket
  `ok-release-artifacts`. Plumage and O+K Trust are not feed dependencies.
- Release builds enable automatic checks and installation by default. The menu
  item **Install Updates Automatically** opts out of automatic installation but
  does not disable scheduled checks. Manual **Check for Updates…** remains
  available.
- Debug builds set automatic checks and installation off so they cannot replace
  themselves from the public stable channel in the background.
- Sparkle requires a signed feed, verifies the archive before extraction, and
  schedules release-build checks every 86,400 seconds. Requests contain no
  installation id, account data, usage, or provider credentials.
- Publication uploads the immutable archive first and verifies its public
  SHA-256 readback. It advances `stable/appcast.xml` last and verifies the
  signed feed, enclosure URL, and build before publishing O+K Trust provenance
  and then the deduplicated `product.release_available` Chirp event.
- O+K Trust is secondary provenance, not executable update authority. Installed
  apps never poll Chirp or contain Chirp operator credentials.
- The technical alpha is ad-hoc signed and may require Gatekeeper **Open
  Anyway** on first installation. Pre-Sparkle users require one manual bridge
  installation.
- A future Developer ID transition keeps the bundle identifier, feed URL, and
  Sparkle Ed25519 key stable. Do not rotate the Ed25519 key in the same release
  that introduces Developer ID signing and notarization.

## Implementation Shape

- The native Swift app is canonical: provider clients feed `UsageStore`, which
  reconciles persistent last-known data and renders the menu-bar status item.
- The Node CLI and SwiftBar script remain optional diagnostics/fallbacks and do
  not own native cache or scheduling behavior.
- Sparkle's signed R2 feed and archive are the native updater's release truth.
  O+K Trust is secondary provenance and Chirp is publisher-side notification
  fan-out.

## Open Questions

- Should thresholds be configurable per user?
- Should reset times be displayed as wall-clock time, duration, or both?
- Decided against Keychain write-back auto-refresh: updating the item via the `security` CLI can reset its ACL and lock Claude Code out of its own credential (this is why Astra stays read-only). The always-live path is instead a long-lived token from `claude setup-token` placed in the env/token-file.
- Additional active Anthropic `limits[]` entries beyond Fable currently render
  as dropdown-only rows with no dial marker. Whether any of them need their own
  marker styles remains undecided.
