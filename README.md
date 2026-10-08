# Alight

Alight is a tiny macOS menu bar gauge for **Codex, Claude Code, and Antigravity** usage pressure.

The dial is a dark circle with a dotted gauge scale, up to six hands, and optional scoped-limit markers. Hands are drawn as bold lines in **separate radial bands** (so they never swallow each other when their angles align): the long (weekly) window is a long line from the hub out past the tick marks, and the short (~5h) window is a short line in the outer band crossing the ticks (an emphasized tick). They are vivid against the dark face (with only a thin dark edge for separation) — the most dominant element. The scale recedes to small white dots; the only colored part of the scale is a **solid pure-red (`#FF0000`) redline arc on the hot end** — the side that actually matters.

Hands are deconflicted on three axes:

- **provider → color:** Codex is teal, Claude is coral, Antigravity is purple.
- **window → length:** the slow (weekly) window is a long hand; the fast (~5h) window is a short outer-band hand.
- **scoped limit → marker:** active Claude Fable weekly usage appears as a four-pointed coral star on the outer edge. It follows the latest fresh Anthropic reading, and disappears when a later successful response no longer includes that active scoped limit. Any other active scoped weekly limit (such as 3P model quotas in Antigravity) surfaces as a dropdown-only row and stays off the dial; the star remains reserved for Fable.
- **pressure → depth:** the most-constrained (highest-pressure) window draws on top, so the hand that matters most is in the foreground.

So a long teal hand is Codex's weekly window when that is the Codex limit the API reports; a short coral hand is Claude's 5-hour window; a long purple hand is Antigravity's weekly Gemini quota; a short purple hand is Antigravity's 5-hour Gemini quota; a coral star is Claude's active Fable scoped weekly limit.

The open clock hands in the unused bottom arc show reset phase for every active broad limit without adding another dial face. They rotate clockwise through their complete window and return to 12 at reset. Seven ticks on the inner weekly track make each interval one day; five ticks on the outer 5h track make each interval one hour. A hand stops just inside its matching track, provider remains encoded by color, and a track appears only when that kind of limit exists. The complete time display sits behind the quota display, so quota hands and scoped markers remain visually dominant where they cross. Scoped limits remain off the reset clock to keep it legible. The dropdown gives the exact local reset time and countdown for every displayed limit.

The hands are pace-relative consumption meters. A hand pegged left means `0%` consumed, centered means exactly on the expected reset pace, and pegged right means `100%` consumed / `0%` remaining.

When a provider isn't signed in (or its token has expired), the dropdown shows a **Sign in to …** item that launches that CLI's login flow in Terminal (`codex login` / `claude auth login` / `agy`); after signing in, hit Refresh.

The menu groups windows by provider and uses a simple pressure color per window:

- blue: high / too cold / plenty of slack
- green: good / on pace
- red: low / too hot / usage is ahead of pace

The **Display Mode** menu lets you switch between:
- **Gauge**: The circular dial with pace-relative hands, redline danger arc, and reset clock hands.
- **Meters**: One dark card per provider (Codex, Claude, Antigravity), each with a small colored square on the left and one colored track per limit window on the right: weekly on top and thicker, ~5h below and thinner, plus a thin third track for Claude's active Fable limit. A white bar on each track shows usage (or what remains, in Empty mode), and a dot marks how far through the window the clock is: drawn in the provider color where it sits on the bar (usage ahead of the clock), white where it sits on the track (clock ahead of usage), and two-toned when they are about even.

The **Icon Settings** submenu lets you tune the menu-bar glyph without editing
code. Slider controls persist local point values for Fable star size/radius,
short-window hand length/width/radius, weekly hand length/width/radius, scale dot
size/radius, redline width, hub dot size, and meter width. Color choices for Codex, Claude,
Antigravity, and the redline, as well as meter label style, fill style, and direction choices, are persisted alongside them. Radius sliders are intentionally
permissive: elements can be pushed off the dial and will only stop when the icon
canvas itself clips them.

The native app:

- reads local Codex auth from `~/.codex/auth.json` and calls the ChatGPT usage endpoint Codex uses;
- runs Claude Code's own headless `/usage` command (`claude -p /usage --output-format json`), mapping its current session onto the fast hand, its all-models week (when the plan has one) onto the slow hand, and its Fable week onto the outer-edge star;
- reads local Antigravity credentials and queries the native Antigravity backend (`daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`), mapping the Gemini 5-hour and weekly limits to fast/slow purple hands and secondary model groups to dropdown menu rows.

It never prints or stores credentials. Each provider is polled independently, so one being unavailable never blocks the others. Alight persists only derived last-known usage (percentages, reset times, and capture time) under Application Support. A credential or endpoint failure keeps still-valid hands visible with their age and the current recovery warning; each cached hand retires at its own reset boundary, and no cached reading older than six hours is shown. Cached pressure is recalculated against the current clock instead of freezing at capture time.

### Usage insights source milestone

`UsageStore.history` extends the existing single-flight refresh path: successful
raw live results are recorded at request completion, before cache reconciliation.
Cached, deferred, or failed refreshes never invent history. Derived observations
live in `Application Support/Alight/usage-history.json`, capped at 14 days and
20,000 points. This supplements the existing last-good cache without changing its
document format. History load/save warnings appear in the insights view while
live gauges continue working. No credentials, tokens, or raw account IDs enter
history. Codex account partitions use a domain-separated SHA-256 reference from
the same auth snapshot that supplied the request.

`UsageInsightsView(store:)` and `UsageInsightsWindowController(store:)` are a
reusable chart and thin window host. Open **Usage History…** from the Alight menu.
The menu retains one window controller using the gauge's existing store, including
after closing and reopening the window. Opening it creates no polling or provider
runtime. Source tests cover menu dispatch and window reuse with synthetic data;
installed-release acceptance remains separate.

The view charts live observations over the past 24 hours and presents sustainable
pace, recent rate, time to zero within the current quota window, and projected
remaining allowance or quota overrun at reset and calendar week end. Overrun means
extrapolated demand in percentage points, never billing overage or money. A week
end beyond the current provider reset is unavailable, since the next allowance is
unknown. Rate variation is labeled as observed variation, not a confidence interval.

Forecasts require a verified account/source partition and at least three recent
readings spanning ten minutes. Account/source/reset/duration/reported-limit changes,
usage decreases and gaps over fifteen minutes break continuity. Thin, zero-rate,
stale, reversed-clock and expired data yield an explicit reason and recovery text.
Claude readings carry a hashed account identity from `claude auth status`, so
they join like Codex readings. Antigravity currently exposes no verified account
identity in its result contract: its observations are isolated points with
forecasts unavailable. Codex without an account ID behaves the same way. An unreported plan/denominator
change cannot be detected from percentages; projections explicitly retain that
limitation rather than inventing a quota amount.

Tests cover capture eligibility, provider/fast/slow separation, lineage, gaps,
account opacity, persistence/restart/errors, retention, stale and thin coverage,
zero/decreased usage, runway arithmetic and reset horizons. Offline verification
uses `swift test --skip liveFetchIfCredentialsExist` to exclude the existing live
Antigravity probe; use ordinary resource admission and cached dependencies when
provider calls are out of scope. Mounting the real window and discoverable menu
integration still require the separate UI custody and visual acceptance gates.

### Claude Code usage

Alight asks Claude Code itself. Each Claude poll runs, directly and without a shell:

```sh
claude auth status --json          # which account, and is it signed in?
claude -p /usage --output-format json --no-session-persistence --safe-mode
```

`/usage` is a local command: Claude Code answers it without a model turn (no inference, no cost) and handles its own login and token renewal. Alight reads no Claude credentials, never touches the `Claude Code-credentials` Keychain item, and makes no Anthropic request of its own. If Claude Code ever answers `/usage` with a model turn, Alight refuses the reading and stops scheduled Claude polls until you press Refresh. `--safe-mode` keeps each poll from loading your hooks, plugins, and MCP servers.

- **Cost:** measured on Claude Code 2.1.286, `/usage` takes 2-4 s and about 1.8 CPU-seconds (it also summarizes local sessions), `auth status` about 0.2 s; at the three-minute cadence, roughly 15 CPU-minutes a day.
- **CLI location:** `ALIGHT_CLAUDE_CLI`, else the first of `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`, `~/.volta/bin/claude`, `~/.bun/bin/claude`, and the newest `~/.nvm/versions/node/*/bin/claude`.
- **Isolation:** stdin is `/dev/null`, the working directory is `~/Library/Application Support/Alight`, the environment is only `HOME`, `USER`, `PATH`, `TMPDIR`, `LANG=en_US.UTF-8` and `DISABLE_AUTOUPDATER=1`, signals start unblocked, output is bounded, and a 30-second deadline sends SIGTERM, then SIGKILL, to the CLI's whole process group. Alight writes nothing under `~/.claude`; Claude Code may update its own state (`~/.claude.json`, its token).
- **Plans:** a Team seat reports only a session limit plus model-scoped weeks (such as Fable); that is a complete reading. Pro/Max plans also report `Current week (all models)`, and Max/Team plans `Current week (Sonnet only)`, shown as a dropdown row that counts toward the summary's most constrained window.
- **Polling:** at most every three minutes, backing off to fifteen after failures; a signed-out CLI is rechecked every minute, so usage appears within a minute of signing in. Manual Refresh polls immediately. Only one `claude` process runs at a time.
- **Failures** are shown as such (for example `Claude Code /usage timed out` or `unrecognized Claude Code usage line: …`) and never as guessed numbers; between polls the menu keeps the reason and the time of the next attempt. When Claude Code is signed out, the menu offers **Sign in to Claude…** (`claude auth login`).
- **Cache:** a Claude reading is reused only for the same account (a domain-separated SHA-256 of its email and organization plus the plan name; the raw email is never stored). A different, unknown, or signed-out account drops it, and no cached reading older than six hours is shown.

Claude Desktop's always-populated plan display is not a supported alternate source. Alight deliberately does not borrow Desktop cookies or private app state.

### Antigravity credential

Antigravity credentials resolve in precedence order:

1. **`ANTIGRAVITY_OAUTH_TOKEN`** (or `ANTIGRAVITY_TOKEN`, `GEMINI_CLI_OAUTH_TOKEN`) env var.
2. **Token file** — `~/.alight/antigravity-token` (override with `ALIGHT_ANTIGRAVITY_TOKEN_FILE`). First non-comment line.
3. **Antigravity CLI token files** — `~/.gemini/antigravity-cli/antigravity-oauth-token`, `~/.gemini/jetski-standalone-oauth-token`, or `~/.gemini/oauth_creds.json`.
4. **Keychain** (macOS) — `gemini` generic password item containing a base64-encoded `go-keyring-base64` JSON token.

When an access token expires, if a refresh token is present, Alight renews it in-memory against `https://oauth2.googleapis.com/token` without modifying local files or the Keychain. The quota summary URL can be overridden with `ALIGHT_ANTIGRAVITY_USAGE_URL`. The default matches the native `agy` client; the unprefixed Code Assist host can report a different Gemini allowance for the same account. Antigravity cache entries carry a non-secret endpoint fingerprint. Older unbound or different-source Antigravity readings are discarded on load, as are Claude readings from before account binding; Codex cache data is preserved.

### Release updates

Alight source metadata is currently `0.6.0` (build `13`) and embeds Sparkle `2.9.4`. The renamed app is prepared to check the signed feed at `https://updates.owlandkestrel.com/alight/stable/appcast.xml`; that feed is a pending remote cutover and is not claimed as published by this source tree. Release builds check and install updates automatically by default. **Install Updates Automatically** opts out of installation only—scheduled checks continue—and **Check for Updates…** remains available. Debug builds never update themselves automatically. Update traffic contains no installation identifier, account data, usage readings, or Codex/Claude credentials.

The feed and immutable, content-addressed archives will live on the O+K-owned release origin at `updates.owlandkestrel.com`; Plumage and O+K Release/Trust are not feed dependencies. Direct R2 publication is retired. New channel advancement is temporarily frozen until Alight uses Nest's authenticated release-origin client for archive-first, pointer-last publication and exact public readback. Existing Glideslope installations continue to use their historical signed feed during this publisher freeze. See [`docs/releasing.md`](docs/releasing.md) for the coordinated Nest identity and local-data migration.

Alight does not have a standalone web product. Its canonical public page is
`https://owlandkestrel.com/apps/alight`. The optional
`alight.owlandkestrel.com` hostname is a redirect-only convenience surface;
it must not acquire content, application routes, cookies, or a second product
authority. O+K owns that shared redirect surface through its exact ecosystem
allowlist and generated Nginx configuration in
`config/ecosystem-redirects.json`; Alight deliberately carries no second
copy. Cloudflare publishes unproxied A and AAAA records to `ok-spruce`, and the
shared exact-name certificate renews through Certbot. Every HTTP and HTTPS path
returns the same permanent redirect to the canonical Apps page. Removing the
alias never removes the canonical Apps route or Alight release feed.

The technical alpha is ad-hoc signed rather than Developer ID signed/notarized, so its first installation may require **System Settings → Privacy & Security → Open Anyway**. Installed Glideslope apps are not stranded: every Alight release also packages a bridge for the historical Glideslope feed (the same build wrapped as `Glideslope.app`), which Sparkle installs in place; Alight then renames itself to `Alight.app` and continues on its own feed. Pre-Sparkle users need one manual installation. See [`docs/releasing.md`](docs/releasing.md).

After arriving via the bridge or a fresh install, choose **Import Settings**
on first launch to bring across the valid native cache and allowlisted
appearance settings before the status item starts, or choose **Start Fresh**.
Run `npm run migrate:data` with Alight stopped to preview and explicitly apply
the command-line state migration. Destinations are never overwritten, and
credential files are never copied; move user-managed files to `~/.alight/`
manually with mode `0600`.

### Preview

`Alight --render preview.png` rasterizes the dial across a few usage scenarios on both light and dark backgrounds — handy for tuning the hands without watching the live menu bar.

## Requirements

- macOS 14+
- Swift toolchain / Command Line Tools for local builds

No Apple Developer account is required for local unsigned builds. A Developer ID account is only needed later for a polished signed and notarized public DMG.

## Run the Native App

The GitHub/Nest Alight repository rename is still pending. Until that
coordinated cutover is complete, build from the existing local Alight checkout
after the source directory move:

```sh
cd /Users/jon/Projects/alight
./script/build_and_run.sh
```

The script builds a local unsigned app bundle at:

```text
dist/Alight.app
```

## CLI

The original Node CLI remains useful for tests, scripting, and debugging:

```sh
node ./bin/alight.mjs status --json
node ./bin/alight.mjs swiftbar
```

## Optional SwiftBar Renderer

SwiftBar is no longer the recommended default. If you already use SwiftBar and want a text renderer, point SwiftBar at `swiftbar/alight.1m.sh` or run:

```sh
./scripts/install-swiftbar.sh
```

## Fallback

If the private backend endpoint fails, the CLI renders cached state. You can also seed manual values:

```sh
node ./bin/alight.mjs manual \
  --primary-used 20 \
  --primary-reset-at 1779030000 \
  --weekly-used 6 \
  --weekly-reset-at 1779548400
```

CLI state is stored at:

```text
~/.alight/state.json
```

The former `~/.codex-usage-pressure/state.json` path is historical input for
the explicit `npm run migrate:data` command; Alight never reads it as a
runtime fallback.

## Development

```sh
npm test
npm run test:swift
npm run build:native
./script/build_and_run.sh --verify
```

## License

MIT
