# Alight Spec

Alight is a tiny macOS menu bar gauge for coding-agent usage-window pressure. It tracks **Codex, Claude Code, and Antigravity** together.

## Purpose

Both Codex, Claude Code, and Antigravity expose usage remaining, but the signal is buried and raw percentages are hard to interpret. Alight turns each provider's current usage window into a pace reading: whether remaining usage is lower than, equal to, or higher than expected for this point in the window.

The goal is one calm glance, not another dashboard.

## Providers

Alight tracks three providers. Each contributes the windows its usage API currently reports; a provider may expose only one cadence:

- **Codex** — teal hands.
- **Claude Code** — coral hands.
- **Antigravity** — purple hands.

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

- **Provider → hand color.** Codex teal, Claude coral, Antigravity purple.
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

### Display Modes

Alight supports two menu-bar display modes, switchable from the **Display Mode** menu:

1. **Gauge Mode (default)**: The circular dial with pace-relative hands, redline danger arc, Fable star marker, and reset clock in the lower arc.
2. **Meters Mode**: One dark card per provider stacked within the menu bar icon height (22pt):
   - **Cards**: Codex, Claude, Antigravity in that order, every card the same height regardless of how many tracks it holds. A card with an active scoped weekly limit (Claude's Fable) grows to hold a third, thinnest track. Dropdown-only scoped rows are not drawn.
   - **Swatch**: The left of each card is a small square in the provider color, so a maxed-out (all-white) card is still identifiable; bars-only mode omits it.
   - **Tracks**: One per limit window in the provider color; weekly on top and thicker, ~5h below and thinner. A lone track fills its card.
   - **Bar**: A white bar on the track shows usage. **Fill (Used)** grows it as quota is consumed; **Empty (Remaining)** drains it. **Direction** sets the origin side.
   - **Pace dot**: A dot on each track marks `elapsedSeconds / limitWindowSeconds`. Where it lies on the white bar it is drawn in the provider color (usage is ahead of the clock); where it lies on the track it is drawn white (the clock is ahead of usage); straddling the bar's edge it is two-toned (on pace).
   - **Meter Width**: Configurable via slider (20pt to 72pt, default 36pt). The menu-bar item resizes to match.

When a provider needs credentials (not signed in, or token expired/rejected), the dropdown surfaces a **Sign in to …** action that launches that CLI's login in Terminal (`codex login` / `claude auth login` / `agy`).

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

- Run Claude Code's own headless usage command, directly and without a shell:
  `claude -p /usage --output-format json --no-session-persistence --safe-mode`.
  `/usage` is a local command: Claude Code answers it without a model turn
  (`num_turns` 0, cost 0) and owns its login, token renewal, and endpoint.
  Alight reads no Claude credentials and sends no request to Anthropic itself.
  `--no-session-persistence` keeps each poll from saving a session transcript;
  `--safe-mode` keeps it from loading the user's hooks, plugins, and MCP
  servers (login and `/usage` work normally). Measured on Claude Code 2.1.286:
  `/usage` takes 2-4 s and about 1.8 CPU-seconds (it also summarizes local
  sessions, so it grows with transcript volume); `auth status` about 0.2 s.
  At the three-minute cadence that is roughly 15 CPU-minutes a day.
- Find the CLI at `ALIGHT_CLAUDE_CLI` (an absolute path), else the first
  executable of `~/.local/bin/claude`, `/opt/homebrew/bin/claude`,
  `/usr/local/bin/claude`, `~/.claude/local/claude`, `~/.volta/bin/claude`,
  `~/.bun/bin/claude`, and the newest `~/.nvm/versions/node/*/bin/claude`. No
  PATH search or shell lookup.
- Run it with stdin on `/dev/null`, Alight's Application Support folder as the
  working directory, no blocked signals and default signal actions, a
  30-second deadline (then SIGTERM and, a second later, SIGKILL of its whole
  process group), bounded stdout/stderr, and a minimal environment: `HOME`,
  `USER`, `PATH=/usr/bin:/bin:<CLI folder>`, the per-user `TMPDIR`,
  `LANG=en_US.UTF-8` (reset dates always in English), and
  `DISABLE_AUTOUPDATER=1`. Nothing from Alight's own environment is
  forwarded, so `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` cannot switch
  the CLI to another login. Alight writes nothing under `~/.claude` or to the
  Keychain; the CLI it runs may update its own state (`~/.claude.json`, its
  token).
- Accept the JSON only when `type` is `result`, `num_turns` is `0` (and cost
  is zero), `subtype` is `success`, and `local_command` is `usage`. A model
  turn, or a result without a turn count (which cannot rule one out), is
  refused, and scheduled Claude polls stop until a manual Refresh, so a CLI
  that ever treats `/usage` as a prompt cannot spend inference each poll.
- Parse the result text. Claude Code prints one `<title>: N% used` line per
  limit, plus ` · resets <date>` when the limit has a reset time:
  `Current session` → fast 5h window; `Current week (all models)` → slow
  weekly window; `Current week (<Model>)` → a scoped weekly window (`Sonnet
  only` on Max and Team plans, Fable, or any other model). Fable keeps the
  four-pointed star on the dial's outer edge; every other model is a
  dropdown-only row. Scoped rows count toward the most constrained window, so
  the summary can name, for example, `Claude Sonnet`. A `Current session` or
  `Current week` line that cannot be classified or read fails the whole
  reading, so no active limit is silently hidden; a model name containing a
  colon keeps its whole label.
- Resets are read in the IANA zone named in parentheses. Claude Code always
  prints a date and an hour (`resets Oct 8 at 2pm (America/Guayaquil)`;
  `Oct 8, 2:30pm` from a V8 build), and adds the year whenever the reset is
  not in the current year (`Jan 2, 2027 at 9am`). A date without a year is in
  the current year; Alight takes the closest year, which also covers a poll
  that straddles midnight on Dec 31. A time-only reset (`2pm`, the
  formatter's form for a reset within a day when the date is not forced) is
  the next occurrence. A date without a time, or a relative phrase, is
  rejected rather than guessed.
- A reset at or before the reading's time means the window has already reset:
  it is shown as a fresh, unused window rather than its stale percentage. A
  reset more than a day outside the window's own length is a misread.
- A plan may have no weekly limit (a Team seat shows only `Current session`
  plus model-scoped weeks). The command prints every limit the plan has, so a
  reading with at least one broad window is complete.
- Unknown or unparseable output, a timeout, or a failing CLI is an explicit
  failure with a short reason, never a guessed number. A signed-out CLI
  (`auth status` `loggedIn: false`, or a `/login` prompt) asks for **Sign
  in**. A CLI that rejects one of Alight's flags asks for an update.
- **Account binding.** Before `/usage`, `claude auth status --json` identifies
  the account. Only a domain-separated SHA-256 of its email and organization
  (plus the plan name, such as `team`) is kept, never the raw email. That
  identity is the reading's `observationIdentity`, so usage history and
  forecasts can join Claude readings for one account.
- **Gentle polling.** Scheduled Claude polls run at most every three minutes;
  after failures the wait doubles up to fifteen minutes. A signed-out CLI is
  rechecked every minute (only `auth status` runs), so usage appears within a
  minute of signing in. Between polls the menu keeps the latest attempt's
  account, Sign in action, and reason with the time of the next attempt.
  Manual Refresh forces a poll. Scheduled and manual refreshes share one
  in-flight task and the process runner is serial, so two `claude` processes
  never run at once.

### Antigravity

- Resolve the OAuth access token in precedence order:
  1. `ANTIGRAVITY_OAUTH_TOKEN` (or `ANTIGRAVITY_TOKEN`, `GEMINI_CLI_OAUTH_TOKEN`) env var.
  2. Token file `~/.alight/antigravity-token` (override `ALIGHT_ANTIGRAVITY_TOKEN_FILE`).
  3. Local Antigravity CLI token files (`~/.gemini/antigravity-cli/antigravity-oauth-token`, `~/.gemini/jetski-standalone-oauth-token`, `~/.gemini/oauth_creds.json`).
  4. The `gemini` Keychain item via `security find-generic-password -s gemini -w` (decodes `go-keyring-base64`).
- No self-refresh: Alight reads the access token that the `agy` CLI maintains and never refreshes it, never reads or stores a refresh token, and embeds no OAuth client ID or secret (the only working client is Google's own for `agy`, which is not ours to embed or use). An expired token (`expiry` in the past in a CLI file or the Keychain item, with no current token in a later source) is reported as `session expired — run `agy` to refresh` with `needsAuth`, so the dropdown offers **Sign in to Antigravity…** (`agy`). An HTTP 401 from the quota endpoint maps to the same message. No usage or reset values are invented: the existing last-known cache rules apply (cached reading with age, then Offline/Sign In Needed with no hands).
- Call Google Cloud Code PA's `retrieveUserQuotaSummary` endpoint (`https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, overridable via `ALIGHT_ANTIGRAVITY_USAGE_URL`) with `Authorization: Bearer …` and `User-Agent: Antigravity/1.0`.
- Map the primary Gemini group's `gemini-5h` bucket → fast purple hand and `gemini-weekly` bucket → slow purple hand. Each bucket provides `remainingFraction` and `resetTime`.
- Any secondary model groups (such as 3P Claude and GPT models) surface as `.menuRow` scoped windows in the dropdown, keeping the dial clean and focused on primary capacity.

### Native last-known cache

- Persist derived usage windows and capture timestamps at
  `~/Library/Application Support/Alight/usage-cache.json` with mode `0600`.
- Never persist tokens, credential blobs, account ids, or raw provider responses.
- A live failure does not erase still-valid last-known hands. The dropdown shows
  cache age, current error, and the auth action together.
- Recompute cached pressure against the current clock on every refresh.
- Retire each cached hand at its own reset timestamp, and never show a cached
  reading more than six hours old.
- Claude readings are bound to their account: a poll whose account is
  different or unknown (including signed out) drops the cached Claude
  reading, an unidentified live reading is shown but never cached, and older
  unbound Claude entries are ignored on load.
- Claude Desktop private history/cookies are not a fallback source. Its sampled
  history can omit reset times, and its web session is not a supported third-
  party credential surface.

Fallback sources (Codex):

- Cached last-good response at `~/.alight/state.json`
- Manual state written by the local CLI

The former `~/.codex-usage-pressure/state.json` location is a historical input
to the explicit rename migration command. Alight never reads it as a runtime
fallback.

Automatic sources are intentionally primary. Manual input exists only as a resilience path.

## Safety

- Never print or cache any provider auth token.
- Never read Claude Code's credentials; Claude Code owns its own login.
- Cache only derived usage windows and freshness metadata.
- Treat endpoint failures as degraded telemetry, not as zero usage.
- Prefer reset-bounded, stale-but-labeled data over a scary blank state.
- Show credential failures and cached hands together; never disguise cached data
  as a live success.

## Non-Goals

- No in-Codex / in-Claude UI injection.
- No OCR or settings-screen scraping as the normal path.
- No autonomous usage throttling.
- No account sharing, credential export, or third-party service sync.
- No direct Claude Desktop cookie, Chromium-store, or private endpoint access.
- No update installation that bypasses Sparkle's signed-feed and signed-archive
  verification.

## Release Update Channel

- `package.json` is the version and monotonic-build authority. The prepared
  Alight release identity is version `0.6.0`, build `13`, and bundle identifier
  `com.owlandkestrel.alight`.
- The native app embeds exact Sparkle version `2.9.4`. Its executable update
  authority is the Ed25519 public key committed at
  `config/sparkle-ed25519.pub`; the private key never enters the repo, app, feed,
  archive, or log.
- The prepared stable feed is
  `https://updates.owlandkestrel.com/alight/stable/appcast.xml`, served with
  immutable content-addressed archives from dedicated Cloudflare R2 bucket
  `ok-release-artifacts`. The Alight feed remains pending the coordinated Nest
  project cutover; Plumage and O+K Trust are not feed dependencies.
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
- Two menu-bar display modes are supported: the circular Gauge dial (pace hands,
  reset clock, and Fable star) and horizontal Meters (grouped by provider with
  differential track thickness for fast vs. weekly cadence, provider badges,
  and a two-tone pace dot).
- The Node CLI and SwiftBar script remain optional diagnostics/fallbacks and do
  not own native cache or scheduling behavior.
- Sparkle's signed R2 feed and archive are the native updater's release truth.
  O+K Trust is secondary provenance and Chirp is publisher-side notification
  fan-out.

## Open Questions

- Should thresholds be configurable per user?
- Should reset times be displayed as wall-clock time, duration, or both?
- Decided (2026-10-08): read Claude usage only through Claude Code's own
  `/usage` command. Calling `api.anthropic.com/api/oauth/usage` with Claude
  Code's token is no longer workable (it answers HTTP 429 to other clients),
  and presenting Alight as Claude Code was rejected as impersonation.
- Each Claude poll costs a few CPU-seconds. Should the cadence stretch on
  battery, while the screen is locked, or while readings stay unchanged?
- Model-scoped weekly limits beyond Fable currently render as dropdown-only
  rows with no dial marker. Whether any of them need their own marker styles
  remains undecided.
