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

The SwiftBar/Node CLI path has its own disk fallback at
`~/.codex-usage-pressure/state.json`, but the native app does not read that file.
For native freshness bugs, start with `Sources/Glideslope/ClaudeUsageClient.swift`
and `Sources/Glideslope/UsageStore.swift`.

The native cache lives at
`~/Library/Application Support/Glideslope/usage-cache.json`. It contains only
derived usage windows and capture timestamps, is written mode `0600`, and never
contains provider credentials. Cached pressure is recomputed on every refresh;
each hand is removed when its own reset timestamp passes.

## Failure Mode Found

The 2026-05-29 report showed `Claude (cached)` values that disagreed with the
Claude plan-limits page. A direct redacted diagnostic found the native app had
no `~/.glideslope/claude-token`, so it fell back to the Claude Code Keychain
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
its in-memory plan-usage state when a fetch fails. Glideslope instead uses the
Claude Code OAuth credential and `/api/oauth/usage`.

Desktop also writes `plan-usage-history.json`, but that file contains sampled
percentages without reset timestamps and can stop updating while Desktop remains
open. It cannot safely drive Glideslope's pace gauge. Do not read Desktop
cookies, Chromium storage, or private in-process state, and do not piggyback its
web session.

## Refresh Token Experiment

On 2026-07-04, Glideslope showed no Claude hands because the shared
`Claude Code-credentials` Keychain access token had expired on
2026-06-17. The Keychain item still contained a refresh token, and
`claude auth status` reported the account as logged in, but Glideslope does not
use refresh tokens and therefore had zero windows to render.

Raw refresh attempts against `https://api.anthropic.com/v1/oauth/token` using
standard OAuth `grant_type=refresh_token` shapes returned `400 Invalid request
format`, both with and without the `oauth-2025-04-20` beta header and the
public Claude Code client id from `https://claude.ai/oauth/claude-code-client-metadata`.
The endpoint was not proven unsafe, but the request format is app-specific and
should not be guessed in production code.

Invoking Claude Code itself with a tiny non-interactive request refreshed the
Keychain credential safely. On the next one-minute Glideslope credential retry,
the app read the refreshed access token and `/api/oauth/usage` returned live
windows again. This suggests the safest refresh strategy is to let Claude Code
own refresh/write-back, while Glideslope remains a read-only observer.

## Additional Usage Factors

A redacted live payload check on 2026-07-04 confirmed that `/api/oauth/usage`
reports more than the two broad windows Glideslope currently renders. The
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
Glideslope parses the active `weekly_scoped` Fable limit from `limits[]` and
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
  never persisted by Glideslope.
- Availability, authentication, and last-known usage are separate signals. A
  credential failure keeps still-valid cached windows and also shows the
  provider's sign-in action and current error.
- Credential failures should retry local credential reads quickly (currently
  every minute), because Claude Code may refresh the Keychain outside Glideslope.
- Do not implement direct refresh-token use unless the exact Claude Code OAuth
  refresh request shape and refresh-token rotation behavior have been validated.
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
