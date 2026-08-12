# Claude OAuth Refresh and Usage UI Rework

This document records two pieces of work: making the Claude Code tracker survive a stale access token, and reworking how every tracker presents its usage rows. It also records two toolchain defects found along the way, because both will resurface if the workarounds are removed.

## 1. Claude Code always reported "auth expired"

### Root cause

The tracker read Claude Code's stored OAuth access token but never refreshed it. Anthropic's access tokens are short-lived and only the CLI renews them, so a background poller that reads without refreshing gets HTTP 401 whenever the user has not run `claude` recently. `ClaudeQuotaService` mapped that straight to `.expired`, so the failure was permanent rather than transient.

The strategy was taken from the Raycast `agent-usage` extension (`src/claude/fetcher.ts`), which refreshes via `grant_type=refresh_token` against `https://platform.claude.com/v1/oauth/token` with Claude Code's public client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`.

### Design

`ClaudeTokenRefresher` is an actor. Refreshes are serialized because Anthropic rotates the refresh token: two concurrent refreshes would leave one of the two results orphaned and could invalidate the CLI's session. It refreshes on two triggers:

- **Proactively**, when the stored token is within 60 seconds of `expiresAt`.
- **Reactively**, on a 401 from the usage endpoint, with a single retry. This covers clock skew and server-side revocation before the nominal expiry.

### Refusing to refresh when the result cannot be saved

Because the refresh token rotates, a refresh that succeeds but cannot be persisted leaves Claude Code holding an invalidated refresh token — a monitoring app breaking the thing it monitors. `ClaudeTokenRefresher` therefore proves the credential store is writable before spending the token, by rewriting the existing document unchanged. If that write fails it returns `.notWritable` and never contacts the token endpoint.

This is a deliberate divergence from the Raycast extension, which swallows write failures (`fetcher.ts:330-345`).

### Credential handling

`ClaudeCredentialResolver` gained:

- `refreshToken`, `expiresAt`, `scopes`, `subscriptionType`, `rateLimitTier` parsing, plus the raw document so a refresh can round-trip keys the app does not model.
- **Hex decoding.** `security -w` hex-encodes any password whose bytes are not plain printable ASCII, which is a normal shape for this document.
- **File-before-keychain** resolution, matching the CLI's own precedence.
- **Expiry is no longer terminal.** An expired access token backed by a refresh token reports `.valid`; `.expired` is reserved for the case where no refresh is possible.

Keychain access moved to `SecItemCopyMatching` / `SecItemUpdate`, with the `security` CLI kept as a read-only fallback for items whose ACL already trusts `/usr/bin/security` but not this app. Writes never go through the CLI: `security add-generic-password -w <token>` places the refresh token in `argv`, where any local process can read it from `ps`.

### Response parsing

The usage response now also yields model-scoped weekly windows and extra usage:

- `seven_day_<model>` flat keys.
- The structured `limits` array, where `kind == "weekly_scoped"` entries take precedence over the flat key for the same model.
- `extra_usage`, formatted as currency and surfaced in the main window.

## 2. Icon assets

The SVGs in `assets/` are installed into the asset catalog by `tools/flatten_svg_arcs.py`. Re-run it from the repo root whenever a source SVG changes; do not hand-edit the generated files under `Assets.xcassets`.

### actool mis-parses compact SVG arc flags

`actool` renders elliptical arc commands incorrectly when the arc's boolean flags use SVG's compact form, where the large-arc and sweep flags are written with no separator: `a6.105 6.105 0 013.046-.415` packs `0` and `1` into `01`. A parser that scans numbers greedily reads `01` as a single value and shifts every following parameter.

The symptom is a roughly-correct outline with spurious holes and notched curves. Evidence: `codex.svg` has 14 arc commands, `ollama.svg` 26, `cursor.svg` 6, while `claude-color.svg` — which always rendered correctly — has 1. QuickLook, a correct renderer, produced a smooth five-lobed cloud where `actool` produced a notched one with an extra hole.

The script converts every arc to cubic béziers, which `actool` renders correctly, and emits an absolute path using only `M`/`L`/`C`/`Z`. This removes arc handling from the pipeline rather than trying to coax it.

Note that `fill-rule` inheritance is **not** the cause. That was the first hypothesis; an A/B render disproved it.

The script also handles two things `actool` does not resolve: the CSS-only `currentColor` keyword, and `1em` dimensions.

### Rendering intent

`codex`, `cursor`, and `ollama` are monochrome and ship as template images, so they take the surrounding foreground style and stay legible in both appearances. `claude-color` carries a real brand fill (`#D97757`) and renders as authored.

`ollama.svg` is the menu-bar status item icon, applied via `NSImage.borderCollieMenuBarIcon` at 18×18 with `isTemplate = true`.

## 3. Row layout

Usage rows are now icon-left, usage-right. `UsageLimitsGrid` is shared by the main window and the menu-bar panel so the two surfaces cannot drift apart in wording or column alignment. Columns are label, used percentage, reset, with a progress bar spanning each row beneath.

In the menu-bar panel the agent name is carried only as an accessibility label — the icon identifies the agent. The panel widened from 320 to 360 points to fit the third column.

The window title label for seven-day windows is now `7d`, not `Weekly`.

## 4. Reset time formatting

Reset times are **absolute**, not countdowns, and precision follows the distance to the reset rather than the window's nominal length.

| Distance to reset | Renders |
| --- | --- |
| Same calendar day | `resets 1:04 PM` |
| 1–6 days | `resets Thu 10:34 PM` |
| 7 days or more, or already past | `resets Aug 20` |

### Why distance, not window length

Window length is only a proxy for the precision a reader needs, and it breaks at both edges: a seven-day window resetting in twenty minutes would read `Thu`, and a monthly cycle on its final day would read `Aug 20` when it actually resets in two hours. Keying off distance fixes both and replaces the previous three-case `UsageLimitResetStyle` enum, along with its per-agent wiring, with one rule in `UsageResetFormatting`.

### Why absolute rather than a countdown

A countdown is correct only at the instant it renders. It drifts silently between refreshes and can be arbitrarily wrong after sleep/wake. An absolute timestamp stays correct with zero refreshes.

Note that this does **not** reduce network traffic, which was the original motivation for considering it. Nothing polls on the countdown's behalf: `resetText` is a pure function evaluated during body evaluation, and refresh cadence is set by fixed timers in `AgentUsageMenuBarView` and `UsageTrackerView`, throttled independently by `ClaudeUsageRequestGate`. What absolute times buy is that the reset field stops rotting, which is what would *permit* lowering the cadence. Percentages can never be made refresh-independent, so a slower cadence still means stale numbers.

An adaptive format is still chosen at render time, so a stale render can pick a coarser format than warranted. The displayed value stays truthful, just less precise — no correctness regression versus a countdown, which would show a flatly wrong number.

### Two details worth keeping

- **Minutes are retained in the 1–6 day range.** The `EEE j` template truncates rather than rounds, so 8:47 renders as `8 PM`. Cursor's reset timestamps are not on the hour (`03:12:17`), so dropping minutes would be wrong rather than merely coarse.
- **The day boundary is the calendar, not a rolling 24 hours.** A reset 30 minutes away that lands after midnight renders as `Sat 12:30 AM`, not `12:30 AM`; otherwise "11:30 PM" and "11:30 PM tomorrow" are indistinguishable.

The reset column is pinned to `minWidth: 104` so it does not jitter as text shifts between the three forms.

Compact summaries no longer carry a countdown. They now feed only the accessibility label, where a relative duration would have kept exactly the staleness this change removes, somewhere it could not be seen.

## Test notes

### ICU narrow no-break space

`DateFormatter` separates the time from AM/PM with U+202F (narrow no-break space), not the plain space a source literal carries. Assertions comparing formatted times must normalize it, or they fail while printing two identical-looking strings.
