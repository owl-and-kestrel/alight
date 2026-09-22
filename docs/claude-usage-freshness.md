# Claude Usage Freshness

Last investigated: 2026-07-10.

## Native Data Path

The native menu bar app reads Claude usage through `ClaudeUsageClient`, then
`UsageStore` reconciles that result against a derived-data last-good cache before
`StatusItemController` renders the provider section and tooltip.
`UsageStore` emits redacted `OSLog` lines for the Claude poll decision, live
attempt, reconciled status, retry delay, cache age, window count, utilization,
and reset distance; use `./script/build_and_run.sh --logs` for future runtime
checks.

The SwiftBar/Node CLI path stores its state at `~/.alight/state.json`. The
former `~/.codex-usage-pressure/state.json` path is historical migration input;
Alight does not read it as a runtime fallback.
For native freshness bugs, start with `Sources/Alight/ClaudeUsageClient.swift`
and `Sources/Alight/UsageStore.swift`.

The native cache lives at
`~/Library/Application Support/Alight/usage-cache.json`. It contains only
derived usage windows and capture timestamps, is written mode `0600`, and never
contains provider credentials. Cached pressure is recomputed on every refresh;
each hand is removed when its own reset timestamp passes.

During the Glideslope to Alight rename, choose **Import Settings** on Alight's
first launch to copy valid native cache and allowlisted appearance settings
before the status item starts, or choose **Start Fresh**. With Alight stopped,
run `npm run migrate:data` for the preview-first command-line state migration.
Destinations are never overwritten and old data remains in place as recovery
evidence. Credential files are reported for manual mode-`0600` migration; the
app and command never read, rewrite, or delete token bytes.

## Failure Mode Found

The 2026-05-29 report showed `Claude (cached)` values that disagreed with the
Claude plan-limits page. A direct redacted diagnostic found the native app had
no `~/.alight/claude-token`, so it fell back to the Claude Code Keychain
credential. Before Claude Code was reopened, that Keychain access token was
expired. After Claude Code refreshed the Keychain item, `/api/oauth/usage` still
returned HTTP 429 with `Retry-After`; retrying after that delay returned the live
window payload (`five_hour.utilization`, `seven_day.utilization`, and reset
timestamps).

Before the first fix, `UsageStore` reused the last successful Claude windows for
any failure without clearly separating freshness from availability. The July 4
mitigation then swung too far the other way: it erased hands immediately for an
auth failure and after a fixed 15-minute transient TTL. Because the Claude retry
sequence can exceed 15 minutes, this policy directly created the visible
appearing/disappearing behavior.

The 2026-07-10 runtime trace confirmed that the running app was not contacting
the usage endpoint during a disappearance. Its `Claude Code-credentials`
Keychain access token had expired, `ClaudeUsageClient` returned before the HTTP
request, and the cache policy converted a still-known reading into zero windows.
The current policy keeps that reading visible and separately shows the expired
credential plus Sign In action.

## Why Claude Desktop Looks Better

Claude Desktop 1.19367.0 uses a different private path:
`/api/organizations/{organization}/usage` through its authenticated Electron
web session. It polls every five minutes with a 15-second timeout and preserves
its in-memory plan-usage state when a fetch fails. Alight instead uses the
Claude Code OAuth credential and `/api/oauth/usage`.

Desktop also writes `plan-usage-history.json`, but that file contains sampled
percentages without reset timestamps and can stop updating while Desktop remains
open. It cannot safely drive Alight's pace gauge. Do not read Desktop
cookies, Chromium storage, or private in-process state, and do not piggyback its
web session.

## Refresh Token Experiment

On 2026-07-04, Alight showed no Claude hands because the shared
`Claude Code-credentials` Keychain access token had expired on
2026-06-17. The Keychain item still contained a refresh token, and
`claude auth status` reported the account as logged in, but Alight does not
use refresh tokens and therefore had zero windows to render.

Raw refresh attempts against `https://api.anthropic.com/v1/oauth/token` using
standard OAuth `grant_type=refresh_token` shapes returned `400 Invalid request
format`, both with and without the `oauth-2025-04-20` beta header and the
public Claude Code client id from `https://claude.ai/oauth/claude-code-client-metadata`.
The endpoint was not proven unsafe, but the request format is app-specific and
should not be guessed in production code.

Invoking Claude Code itself with a tiny non-interactive request refreshed the
Keychain credential safely. On the next one-minute Alight credential retry,
the app read the refreshed access token and `/api/oauth/usage` returned live
windows again. This suggests the safest refresh strategy is to let Claude Code
own refresh/write-back, while Alight remains a read-only observer.

## CLI Renewal (2026-09-17)

The Keychain login lapsed again from 2026-07-10 until a manual
`claude auth login` on 2026-09-17. Root cause: Claude Code access tokens last
about eight hours and are renewed only when the standalone `claude` CLI runs
inside its five-minute pre-expiry window. The Claude desktop app's Code tab gets
its login from the desktop host and never touches `Claude Code-credentials`, so a
desktop-first user's CLI login is never renewed. By September the item no longer
had a refresh token, so running the CLI could not recover it; only signing in
could.

Reading the desktop app's login instead was rejected: it is a claude.ai web
session cookie behind `Claude Safe Storage`, which grants full account access
rather than scoped OAuth access.

Alight now asks the CLI to renew its own login (`ClaudeCLIRenewal`). When the
Keychain token is within four minutes of expiry, or already expired, and the
item still has a refresh token, Alight runs
`claude mcp get __alight_token_renewal__` and then re-reads the Keychain:

- No inference request is sent. Loading claude.ai connectors renews the OAuth
  token first; the unknown server name then exits 1 without starting any MCP
  server.
- `claude auth status` does not work for this: in Claude Code 2.1.175 it only
  checks that a login exists and never renews it.
- The run uses an empty working directory and drops `CLAUDE_CODE_*`,
  `ANTHROPIC_*`, and `CLAUDECODE` variables, which would otherwise bypass the
  Keychain login. Attempts are at least two minutes apart and time out after
  30 seconds.
- The CLI is found via `ALIGHT_CLAUDE_CLI`, common install paths (including
  the newest nvm Node), and then `$SHELL -lc 'command -v claude'`.
- Alight records only whether a refresh token exists, never its value, and
  still never writes the Keychain.
- A Keychain item with no refresh token shows "Claude Code login lapsed — sign
  in again".

### Timing and grace (2026-09-22)

The first renewal cut still produced visible "Sign in to Claude…" flaps roughly
once per token lifetime. Two causes:

- The renewal was only attempted from the five-minute Claude poll. A poll at
  four and a half minutes before expiry did not renew (outside the four-minute
  lead), and the next poll arrived after expiry, so every cycle briefly showed
  an expired credential and a sign-in prompt before the retry renewed it.
- An expired token with a refresh token was reported with `needsAuth`, so the
  menu offered Sign In even though the CLI would renew it a minute later.

Now every Claude result carries the credential's expiry, and `UsageStore` pulls
the next poll forward to `expiresAt − 4 min + 15 s` (`ClaudeCLIRenewal.
renewalTime`), which lands inside the CLI's five-minute window even with the
one-minute refresh loop. An expired-but-refreshable login is reported with
source `renewing` and no sign-in prompt for a ten-minute grace period
(`ClaudeUsageClient.renewalGrace`); the renewal runs at most once a minute
during that time. A 401 with a refreshable login runs one forced renewal and
retries the request before being treated as a credential failure. Cached hands
stay visible throughout, as before.

## Additional Usage Factors

A redacted live payload check on 2026-07-04 confirmed that `/api/oauth/usage`
reports more than the two broad windows Alight currently renders. The
top-level `five_hour` and `seven_day` objects carry `utilization`,
`used_dollars`, `remaining_dollars`, `limit_dollars`, and `resets_at`.

The response also includes named weekly buckets such as `seven_day_opus`,
`seven_day_sonnet`, `seven_day_oauth_apps`, and several feature-coded buckets;
for the checked account those top-level buckets were present but `null`.

The richer current signal is the `limits` array. In the checked payload it
contained:

- `kind=session`, `group=session`, `percent=0`, reset at the five-hour reset.
- `kind=weekly_all`, `group=weekly`, `percent=44`, reset at the weekly reset.
- `kind=weekly_scoped`, `group=weekly`, `percent=78`, `severity=warning`,
  `is_active=true`, scoped to model `Fable`, reset at the weekly reset.

So Anthropic does expose model/scoped usage such as Fable-only usage, but not
through the older top-level `seven_day_*` object shape in this observed payload.
Alight parses the active `weekly_scoped` Fable limit from `limits[]` and
renders it as a four-pointed star on the dial's outer edge plus a Claude
dropdown row. The Fable marker is stored with the latest successful response so
it does not flicker during deferred polls, but a later successful response that
omits the active scoped limit clears it. The marker size and radius are
controlled by the same local Icon Settings slider surface as the other glyph
geometry controls.

Any further active `weekly_scoped` entries also parse from `limits[]` and
surface as dropdown-only rows with their own reset time and countdown, so no
active scoped usage is silently hidden; they draw nothing on the dial, and the
star remains reserved for Fable pending the marker-style decision in the spec's
open questions.

## Canonical Policy

- A successful provider poll refreshes the last-good cache.
- Successful derived usage is persisted across app relaunches; credentials are
  never persisted by Alight.
- Availability, authentication, and last-known usage are separate signals. A
  credential failure keeps still-valid cached windows and also shows the
  provider's sign-in action and current error.
- Credential failures should retry local credential reads quickly (currently
  every minute), because Claude Code may refresh the Keychain outside Alight.
- Do not implement direct refresh-token use unless the exact Claude Code OAuth
  refresh request shape and refresh-token rotation behavior have been validated.
  Near expiry, let the `claude` CLI renew its own login (see CLI Renewal), and
  schedule that poll from the token's expiry rather than the gentle cadence.
- An expired login that still has a refresh token is a renewal in progress:
  report it as renewing, retry once a minute, and offer Sign In only after the
  grace period or when no refresh token remains.
- HTTP 429 should respect the server's `Retry-After` header. Do not stretch a
  short endpoint cooldown into the generic Claude backoff.
- A cached hand remains eligible only until its own reset timestamp. Its pressure
  is recomputed against the current time, and its age is always disclosed.
- Manual Refresh should force a Claude poll, even when the background cadence is
  waiting for the next gentle poll.
- Manual and scheduled refreshes share one in-flight task so they cannot double
  hit the endpoint or complete out of order.
- Cached provider rows and the tooltip should disclose cache age.

## Safe Diagnostic Shape

When checking Claude freshness, do not print the token. Resolve the credential
source, capture the token into a shell variable, call the usage endpoint with
`curl`, and print only the HTTP status plus the usage-window fields or sanitized
error object.
