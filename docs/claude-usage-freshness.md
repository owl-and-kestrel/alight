# Claude Usage Freshness

Last revised: 2026-10-08 (Claude usage now comes from Claude Code's own
`/usage` command).

## Native Data Path

`ClaudeUsageClient` runs the user's Claude Code CLI through
`BoundedProcessRunner` (direct `posix_spawn`, no shell):

1. `claude auth status --json`. `loggedIn: false` stops here with a sign-in
   prompt. Otherwise its email and organization become a domain-separated
   SHA-256 account identity, with the plan name (`team`, `max`, …) as the
   limit identity. The raw email never leaves the client.
2. `claude -p /usage --output-format json --no-session-persistence`. `/usage`
   is a local command: Claude Code answers without a model turn (`num_turns`
   0, `total_cost_usd` 0, about a second) and handles its own login, token
   renewal, and endpoint.

`UsageStore` reconciles the result with the last-good cache before
`StatusItemController` renders the provider section and tooltip. It emits
redacted `OSLog` lines for the Claude poll decision, live attempt, reconciled
status, cache age, window count, utilization, and reset distance; use
`./script/build_and_run.sh --logs` for runtime checks.

For native freshness bugs, start with `Sources/Alight/ClaudeUsageClient.swift`
and `Sources/Alight/UsageStore.swift`.

### Process contract

- CLI: `ALIGHT_CLAUDE_BIN`, else the first executable of `~/.local/bin/claude`,
  `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`,
  `~/.claude/local/claude`. A login item does not inherit the shell `PATH`, so
  there is no PATH search.
- Environment: only `HOME`, `USER`, `PATH=/usr/bin:/bin:<CLI folder>` (an npm
  install finds `node` there), `LANG=en_US.UTF-8` (reset dates in English), and
  `DISABLE_AUTOUPDATER=1` (a poll never updates Claude Code). Alight's own
  environment, including any `CLAUDE_CODE_*` or `ANTHROPIC_*` variable, is not
  forwarded, so the CLI always uses its normal login.
- stdin `/dev/null`; working directory `~/Library/Application Support/Alight`
  (no project settings or instructions are picked up); stdout and stderr each
  capped at 256 KiB; 30-second deadline, then SIGTERM and, one second later,
  SIGKILL to the CLI's whole process group. The child is reaped before the
  call returns. Runs are serialized, so two `claude` processes never overlap.
- `--no-session-persistence` matters: without it each poll saves a ~4 KB
  resumable session under `~/.claude/projects/`, about 480 a day.

### Output contract

The JSON must be `type: "result"`, `num_turns: 0` with zero cost, `subtype:
"success"`, and `local_command: "usage"`. A model turn is refused (source
`refused`) and scheduled Claude polls stop until a manual Refresh, so a CLI
that ever treats `/usage` as a prompt cannot spend inference every poll.

Sample `result` text from a Team seat (Claude Code 2.1.286):

```text
You are currently using your subscription to power your Claude Code usage

Current session: 16% used · resets Oct 8 at 2pm (America/Guayaquil)
Current week (Fable): 0% used · resets Oct 8 at 7pm (America/Guayaquil)

What's contributing to your limits usage?
…
```

- `Current session` → fast 5h window.
- `Current week (all models)` (Pro/Max) → slow weekly window.
- `Current week (<Model>)` → scoped weekly window. Fable keeps the
  outer-edge star (`UsageScope.fable`); any other model is a dropdown-only row.
  A trailing ` only` (`Sonnet only`) is dropped from the name.
- Percent: `N% used`, or `N% left` / `N% remaining` converted to used.
- Reset: the IANA zone in parentheses (else the system zone, which the CLI
  also uses); `Oct 8 at 2pm`, `Oct 8, 2:30pm`, `Oct 8 at 14:00`, `2pm` (next
  occurrence), `Oct 8` (midnight), or `in 3h 12m`. A date with no year takes
  the year closest to now, so a December poll reads `Jan 2` as next year. A
  reset more than a day outside the window's own length is a misread.
- An unused window with no reset clause is treated as a fresh window; a used
  one without a reset fails.
- Lines not starting with `Current session` / `Current week` (the usage
  breakdown) are ignored. A recognized line that cannot be read fails the whole
  reading, because dropping it could make a weekly plan look session-only.

A reading needs at least one broad window. A Team seat has only `Current
session` plus model-scoped weeks; the command prints every limit the plan has,
so that reading is complete. When Claude Code is signed out, or logged in
without a Claude plan, `/usage` prints a session cost summary (`Total cost:
$0.0000 …`) with no limit lines. Alight reports that as "no plan usage limits"
rather than zero usage.

Failures (CLI missing, timeout, oversized output, non-JSON, non-zero exit,
unrecognized text) become explicit messages, such as `Claude Code /usage timed
out` or `Claude Code exited with status 1: error: unknown option …`. They
never become numbers.

## Canonical Policy

- Scheduled Claude polls run at most every three minutes. After a failure the
  wait is three minutes, doubling up to fifteen; success resets it. Manual
  Refresh polls immediately. Scheduled and manual refreshes share one in-flight
  task.
- A successful reading refreshes the last-good cache. Successful derived usage
  is persisted across relaunches in
  `~/Library/Application Support/Alight/usage-cache.json` (mode `0600`). It
  holds only derived windows, capture times, and provenance digests.
- A failure may show still-valid cached windows with their age and the current
  error. Cached pressure is recomputed on every refresh; each window retires at
  its own reset, and no cached reading older than six hours is shown
  (`UsageResultCache.maxCacheAge`).
- Claude readings are bound to the account that produced them (the
  `sourceIdentity` of the cache entry is the account digest plus plan). A poll
  whose account is different or unknown, including a signed-out CLI, drops the
  cached Claude reading. A live reading with no identity is shown but not
  cached. Deferred cycles carry the identity of the latest attempt. Unbound
  Claude entries written by earlier versions are ignored on load; Codex and
  Antigravity entries are unaffected, so the cache version is unchanged.
- Cached provider rows and the tooltip disclose cache age.

## History

- **2026-05 to 2026-07: Keychain token + `/api/oauth/usage`.** Alight read
  Claude Code's OAuth token (env, `~/.alight/claude-token`, or the
  `Claude Code-credentials` Keychain item via `security`) and called
  `https://api.anthropic.com/api/oauth/usage`. Recurring problems: expired
  Keychain tokens (only the standalone CLI renews them, inside a five-minute
  pre-expiry window), HTTP 429 with `Retry-After`, and cache policies that
  either hid fresh failures or erased still-valid hands.
- **2026-09: CLI renewal.** Alight ran `claude mcp get
  __alight_token_renewal__` near expiry so the CLI would renew its own token,
  then re-read the Keychain, with a renewal grace period before asking for
  sign-in.
- **2026-10-08: replaced.** The endpoint began answering HTTP 429 to any client
  that does not identify as Claude Code. A fix that sent a `claude-code/*`
  User-Agent was rejected as impersonation. Separately, the unbound last-good
  cache kept showing a 39-hour-old reading from a previous login, and a Team
  seat (session limit only) was rejected as an incomplete response. Asking
  Claude Code for `/usage` removes the token reading, the private endpoint
  client, and the renewal workaround; the six-hour cache limit, account
  binding, and session-only acceptance fix the other two.

Claude Desktop's plan display uses its own web session and organization usage
route. Do not read Desktop cookies, Chromium storage, or private in-process
state, and do not piggyback its web session.
