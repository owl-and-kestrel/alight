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
2. `claude -p /usage --output-format json --no-session-persistence
   --safe-mode`. `/usage` is a local command: Claude Code answers without a
   model turn (`num_turns` 0, `total_cost_usd` 0) and handles its own login,
   token renewal, and endpoint. Measured on 2.1.286 (Team seat): 2-4 s wall,
   about 1.8 CPU-seconds and 330 MB peak, because it also summarizes local
   sessions; `auth status` is about 0.2 s. At the three-minute cadence that is
   about 480 polls and 15 CPU-minutes a day.

`UsageStore` reconciles the result with the last-good cache before
`StatusItemController` renders the provider section and tooltip. It emits
redacted `OSLog` lines for the Claude poll decision, live attempt, reconciled
status, cache age, window count, utilization, and reset distance; use
`./script/build_and_run.sh --logs` for runtime checks.

For native freshness bugs, start with `Sources/Alight/ClaudeUsageClient.swift`
and `Sources/Alight/UsageStore.swift`.

### Process contract

- CLI: `ALIGHT_CLAUDE_CLI` (absolute path), else the first executable of
  `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`,
  `~/.claude/local/claude`, `~/.volta/bin/claude`, `~/.bun/bin/claude`, and the
  newest `~/.nvm/versions/node/*/bin/claude`. A login item does not inherit the
  shell `PATH`, so there is no PATH search and no shell lookup.
- Environment: only `HOME`, `USER`, `PATH=/usr/bin:/bin:<CLI folder>` (an npm
  install finds `node` there), the per-user `TMPDIR`, `LANG=en_US.UTF-8` (reset
  dates in English), and `DISABLE_AUTOUPDATER=1` (a poll never updates Claude
  Code). Alight's own environment, including any `CLAUDE_CODE_*` or
  `ANTHROPIC_*` variable, is not forwarded, so the CLI always uses its normal
  login.
- stdin `/dev/null`; working directory `~/Library/Application Support/Alight`
  (no project settings or instructions are picked up); stdout and stderr each
  capped at 256 KiB; 30-second deadline, then SIGTERM and, one second later,
  SIGKILL to the CLI's whole process group. The child is reaped before the
  call returns. Runs are serialized, so two `claude` processes never overlap.
- Signals: runs are spawned from a dispatch worker thread, which blocks most
  signals. The child gets an empty signal mask and default signal actions
  (`POSIX_SPAWN_SETSIGMASK` / `POSIX_SPAWN_SETSIGDEF`); without them it ran
  with SIGTERM, SIGCHLD, SIGINT and SIGHUP blocked, ignored the deadline's
  SIGTERM, and a CLI left behind by a quitting Alight could only be stopped
  with SIGKILL. If the child is reaped elsewhere (`ECHILD`), the run fails
  without signaling the possibly reused process group.
- `--no-session-persistence` matters: without it each poll saves a ~4 KB
  resumable session under `~/.claude/projects/`, about 480 a day.
  `--safe-mode` keeps each poll from loading the user's hooks, plugins, and
  MCP servers; without it every poll fires SessionStart and SessionEnd hooks.
  With both flags no project directory is created for the working directory.
- Alight writes nothing under `~/.claude` or to the Keychain. Claude Code
  itself may update `~/.claude.json` and renew its own token, as intended.

### Output contract

The JSON must be `type: "result"`, `num_turns: 0` with zero cost, `subtype:
"success"`, and `local_command: "usage"`. A model turn, or a result without
`num_turns` (which cannot rule one out), is refused (source `refused`) and
scheduled Claude polls stop until a manual Refresh, so a CLI that ever treats
`/usage` as a prompt cannot spend inference every poll.

Claude Code 2.1.286 builds each limit line as `<title>: <floor(utilization)>%
used`, plus ` · resets <date>` when the limit has a reset time, and prints the
date with its own formatter forced to show the date, the hour (minutes only
when non-zero), and the zone; it adds the year only when the reset is not in
the current year. Utilization is floored to whole percents, so readings are up
to a point less precise than the old endpoint's.

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
  A trailing ` only` (`Sonnet only`, Max and Team plans) is dropped from the
  name. Scoped rows count toward `UsageStatus.worst`, so the summary can name
  `Claude Sonnet`. The label ends at the colon before the percentage, so a
  model name containing a colon stays whole.
- Percent: `N% used`, or `N% left` / `N% remaining` converted to used.
- Reset: the IANA zone in parentheses (else the system zone, which the CLI
  also uses). JavaScriptCore builds print `Oct 8 at 2pm` and, for another
  year, `Jan 2, 2027 at 9am`; V8 prints `Oct 8, 2:30pm` and `Jan 2, 2027,
  9am`. 24-hour `Oct 8 at 14:00` is accepted. A date without a year is in the
  current year; Alight takes the closest year, which also covers a poll that
  straddles midnight on Dec 31. Time only (`2pm`, the formatter's form for a
  reset within a day when the date is not forced) is the next occurrence. A
  date without a time or a relative phrase is rejected: Claude Code never
  prints one for `/usage`, and a date read as midnight could be a day wrong.
  During a fall-back hour an ambiguous wall time reads as its first
  occurrence (at most an hour early, once a year).
- A reset more than a day outside the window's own length is a misread. A
  reset at or before the reading's time means the window already reset: it is
  shown as a fresh, unused window, not its stale percentage.
- An unused window with no reset clause is treated as a fresh window; a used
  one without a reset fails.
- Lines not starting with `Current session` / `Current week` (the usage
  breakdown, spend limits) are ignored. A limit line that cannot be classified
  or read fails the whole reading, because dropping it could hide an active
  limit or make a weekly plan look session-only.

A reading needs at least one broad window. A Team seat has only `Current
session` plus model-scoped weeks; the command prints every limit the plan has,
so that reading is complete. When Claude Code is signed out, or logged in
without a Claude plan, `/usage` prints a session cost summary (`Total cost:
$0.0000 …`) with no limit lines. Alight reports that as "no plan usage limits"
rather than zero usage.

Failures (CLI missing, timeout, oversized output, non-JSON, non-zero exit,
unrecognized text) become explicit messages, such as `Claude Code /usage timed
out`, `Claude Code exited with status 1: …`, or `update Claude Code (error:
unknown option '--safe-mode')` for a CLI older than a flag Alight passes.
They never become numbers. A long reason wraps to two lines in the menu, and
its full text is the tooltip.

## Canonical Policy

- Scheduled Claude polls run at most every three minutes. After a failure the
  wait is three minutes, doubling up to fifteen; success resets it. A
  signed-out CLI (`auth status` `loggedIn: false`) is rechecked every minute
  without backoff: only that local check runs, and usage is read in the same
  poll once the user signs in. Manual Refresh polls immediately. Scheduled and
  manual refreshes share one in-flight task. `ClaudePollSchedule` in
  `UsageStore.swift` owns this policy.
- Between polls, deferred cycles carry the latest attempt's account, sign-in
  state, and reason (`not signed in to Claude Code · retry in 45s`), so the
  menu keeps **Sign in to Claude…** and actionable errors visible. A refusal
  keeps its `Update Claude Code, then Refresh` reason. Over a cached reading,
  the status label's tooltip shows the reason.
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
- **2026-10-08: review fixes.** Reset dates in another year (`Jan 2, 2027 at
  9am`) were rejected, which would have dropped the Claude reading around
  every New Year; the parser now reads the stated year. The child process
  inherited a dispatch thread's blocked signals and ignored SIGTERM; it now
  starts with a clean mask. The one-minute signed-out recheck, lost in the
  switch, is back, and deferred cycles keep Sign in visible. The
  CLI override keeps its original name, `ALIGHT_CLAUDE_CLI`, and Volta, Bun
  and nvm installs are found again without a shell.

Claude Desktop's plan display uses its own web session and organization usage
route. Do not read Desktop cookies, Chromium storage, or private in-process
state, and do not piggyback its web session.
