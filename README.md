# Glideslope

Glideslope is a tiny macOS menu bar gauge for **Codex, Claude Code, and Antigravity** usage pressure.

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

The **Icon Settings** submenu lets you tune the menu-bar glyph without editing
code. Slider controls persist local point values for Fable star size/radius,
short-window hand length/width/radius, weekly hand length/width/radius, scale dot
size/radius, redline width, and hub dot size. Color choices for Codex, Claude,
Antigravity, and the redline are persisted alongside them. Radius sliders are intentionally
permissive: elements can be pushed off the dial and will only stop when the icon
canvas itself clips them.

The native app:

- reads local Codex auth from `~/.codex/auth.json` and calls the ChatGPT usage endpoint Codex uses;
- gets a Claude Code OAuth token and calls Anthropic's subscription usage endpoint (`/api/oauth/usage`), mapping the `five_hour` / `seven_day` windows onto the fast/slow hands and active Fable `limits[]` usage onto the outer-edge star;
- reads local Antigravity credentials and queries the native Antigravity backend (`daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`), mapping the Gemini 5-hour and weekly limits to fast/slow purple hands and secondary model groups to dropdown menu rows.

It never prints or stores credentials. Each provider is polled independently, so one being unavailable never blocks the others. Glideslope persists only derived last-known usage (percentages, reset times, and capture time) under Application Support. A credential or endpoint failure keeps still-valid hands visible with their age and the current recovery warning; each cached hand retires at its own reset boundary. Cached pressure is recalculated against the current clock instead of freezing at capture time.

### Claude Code credential

The reader is **read-only** and never writes to the Keychain (writing back a rotated token via the `security` CLI can reset the item's ACL and lock Claude Code out of its own credential — so we don't). The token is resolved in precedence order:

1. **`CLAUDE_CODE_OAUTH_TOKEN`** env var.
2. **Token file** — `~/.glideslope/claude-token` (override with `GLIDESLOPE_CLAUDE_TOKEN_FILE`). First non-comment line. This is the reliable channel for a menu-bar/login-item app, which does not inherit your shell environment.
3. **Keychain** (macOS) — shell out to the trusted `security` binary for the `Claude Code-credentials` item (mirrors Astra's `providers/cli.py`). An unsigned app reading it directly via the Security framework fails the ACL check, so the `security` route is what works. macOS may ask permission — choose *Always Allow*.

For an **always-live** Claude hand without keychain risk, mint a long-lived token and drop it in the file:

```sh
claude setup-token
mkdir -p ~/.glideslope
printf '%s\n' '<token>' > ~/.glideslope/claude-token
chmod 600 ~/.glideslope/claude-token
```

When relying only on the Keychain, an expired access token degrades to `token expired — open Claude Code to refresh` until Claude Code renews it. The usage URL can be overridden with `GLIDESLOPE_CLAUDE_USAGE_URL`. Manual Refresh forces a Claude usage poll; the background loop polls Claude gently, respects server `Retry-After` cooldowns, coalesces overlapping refreshes, and labels fallback data with cache age.

Claude Desktop's always-populated plan display is not a supported alternate source. Desktop uses its own web session and organization usage route, while Glideslope uses the separate Claude Code OAuth credential. Glideslope deliberately does not borrow Desktop cookies or private app state.

> Glideslope intentionally does not refresh or rewrite Claude Code's shared Keychain item. The durable credential path is a user-created `claude setup-token`; the durable display path is the explicitly aged, reset-bounded last-known cache.

### Antigravity credential

Antigravity credentials resolve in precedence order:

1. **`ANTIGRAVITY_OAUTH_TOKEN`** (or `ANTIGRAVITY_TOKEN`, `GEMINI_CLI_OAUTH_TOKEN`) env var.
2. **Token file** — `~/.glideslope/antigravity-token` (override with `GLIDESLOPE_ANTIGRAVITY_TOKEN_FILE`). First non-comment line.
3. **Antigravity CLI token files** — `~/.gemini/antigravity-cli/antigravity-oauth-token`, `~/.gemini/jetski-standalone-oauth-token`, or `~/.gemini/oauth_creds.json`.
4. **Keychain** (macOS) — `gemini` generic password item containing a base64-encoded `go-keyring-base64` JSON token.

When an access token expires, if a refresh token is present, Glideslope renews it in-memory against `https://oauth2.googleapis.com/token` without modifying local files or the Keychain. The quota summary URL can be overridden with `GLIDESLOPE_ANTIGRAVITY_USAGE_URL`. The default matches the native `agy` client; the unprefixed Code Assist host can report a different Gemini allowance for the same account. Antigravity cache entries carry a non-secret endpoint fingerprint. Version 0.5.1 discards older unbound or different-source Antigravity readings while preserving Codex and Claude cache data.

### Release updates

Prepared Glideslope `0.5.2` (build `12`) is a temporary signed rename announcement for the historical `https://updates.owlandkestrel.com/glideslope/stable/appcast.xml` feed; it is not published by this checkout. Its first launch offers **Download Alight**, which opens `https://owlandkestrel.com/apps/alight` for a user-initiated manual install. Sparkle cannot cross the bundle identity change, so this bridge never attempts to install Alight itself. Run Alight's explicit `npm run migrate:data` command afterward to preview and apply non-secret state migration; credential files remain manual. Earlier Glideslope installs continue on the historical feed during the Alight cutover. Release builds check and install same-identity updates automatically by default. **Install Updates Automatically** opts out of installation only—scheduled checks continue—and **Check for Updates…** remains available. Debug builds never update themselves automatically. Update traffic contains no installation identifier, account data, usage readings, or Codex/Claude credentials.

The feed and immutable, content-addressed archives live on the O+K-owned release origin at `updates.owlandkestrel.com`; Plumage and O+K Release/Trust are not feed dependencies. Direct R2 publication is retired. New channel advancement is temporarily frozen until Glideslope uses Nest's authenticated release-origin client for archive-first, pointer-last publication and exact public readback. Installed apps continue to receive the current signed feed normally during this publisher freeze.

Glideslope does not have a standalone web product. Its canonical public page is
`https://owlandkestrel.com/apps/glideslope`. The optional
`glideslope.owlandkestrel.com` hostname is a redirect-only convenience surface;
it must not acquire content, application routes, cookies, or a second product
authority. O+K owns that shared redirect surface through its exact ecosystem
allowlist and generated Nginx configuration in
`config/ecosystem-redirects.json`; Glideslope deliberately carries no second
copy. Cloudflare publishes unproxied A and AAAA records to `ok-spruce`, and the
shared exact-name certificate renews through Certbot. Every HTTP and HTTPS path
returns the same permanent redirect to the canonical Apps page. Removing the
alias never removes the canonical Apps route or Glideslope release feed.

The technical alpha is ad-hoc signed rather than Developer ID signed/notarized, so its first installation may require **System Settings → Privacy & Security → Open Anyway**. Pre-Sparkle users need one manual bridge installation; later automatic releases can add Developer ID signing through the same feed while preserving the bundle id and Sparkle Ed25519 key. See [`docs/releasing.md`](docs/releasing.md).

### Preview

`Glideslope --render preview.png` rasterizes the dial across a few usage scenarios on both light and dark backgrounds — handy for tuning the hands without watching the live menu bar.

## Requirements

- macOS 14+
- Swift toolchain / Command Line Tools for local builds

No Apple Developer account is required for local unsigned builds. A Developer ID account is only needed later for a polished signed and notarized public DMG.

## Run the Native App

```sh
git clone https://github.com/owl-and-kestrel/glideslope.git
cd glideslope
./script/build_and_run.sh
```

The script builds a local unsigned app bundle at:

```text
dist/Glideslope.app
```

## CLI

The original Node CLI remains useful for tests, scripting, and debugging:

```sh
node ./bin/glideslope.mjs status --json
node ./bin/glideslope.mjs swiftbar
```

## Optional SwiftBar Renderer

SwiftBar is no longer the recommended default. If you already use SwiftBar and want a text renderer, point SwiftBar at `swiftbar/glideslope.1m.sh` or run:

```sh
./scripts/install-swiftbar.sh
```

## Fallback

If the private backend endpoint fails, the CLI renders cached state. You can also seed manual values:

```sh
node ./bin/glideslope.mjs manual \
  --primary-used 20 \
  --primary-reset-at 1779030000 \
  --weekly-used 6 \
  --weekly-reset-at 1779548400
```

CLI fallback state is stored at:

```text
~/.codex-usage-pressure/state.json
```

## Development

```sh
npm test
npm run test:swift
npm run build:native
./script/build_and_run.sh --verify
```

## License

MIT
