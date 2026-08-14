# Usage Tracker Design

This document describes the design of BorderCollie's usage tracking feature and
the standards future trackers should follow. The current implementation tracks
Codex, Cursor, and Claude Code usage. Future trackers should preserve
the same user experience and normalized quota model while isolating each agent's
credential and API details.

For detailed menu-bar interaction and visual rules, read
`docs/menubar-item-design.me`.

Historical token and API-equivalent cost analytics are a separate feature with
a different data model and refresh lifecycle. Read
`docs/usage-dashboard-design.md` and `docs/usage-dashboard-plan.md` before
changing or implementing that dashboard.

## Goals

- Show usage consumed for each supported coding agent.
- Query automatically when a tracker page opens.
- Query automatically when the menu-bar usage popup opens.
- Refresh automatically on a fixed cadence without user configuration.
- Keep a manual toolbar refresh action for recovery and debugging.
- Keep a manual icon-only menu-bar refresh action for quick recovery.
- Normalize provider-specific quota APIs into one UI-friendly model.
- Keep credentials local and never expose tokens in SwiftUI views.
- Make adding a new tracker predictable, testable, and low-risk.

## Current Product Standard

The `Live quota` screen defines the product standard for future trackers:

- The sidebar contains a single `Live quota` destination, not one tab per
  tracker. Every tracked provider is a section on that one page, in product
  order: Codex, Cursor, Claude Code. Comparing two providers should not cost a
  navigation.
- Each section keeps its own view model, poll cadence, and failure state. One
  provider being signed out or rate-limited must never blank another. Do not
  merge them behind a single request or a single loading flag.
- The detail window header title is `Live quota`; the section header carries the
  tracker name and brand icon.
- Do not repeat a tracker name as a large heading in the detail body.
- Auth implementation details are not shown in any user-facing string, in the
  happy path or in an error. "Not signed in to Codex", never "No Codex OAuth
  credentials found".
- Usage percentages and progress bars represent usage consumed.
- The page is a grouped `Form` that fills its pane, one `Section` per tracker.
  The section header carries the agent's brand icon and name; the footer carries
  extra-usage and the updated timestamp. Do not lay a tracker out as a
  fixed-width card pinned to the top-left corner — the pane is as wide as the
  Usage dashboard's.
- The toolbar Refresh refreshes every tracker. A tracker in a failure state also
  offers its own Refresh inline, where its message is.
- Each usage window is shown as:
  - A human label, such as `5h` or `7d`.
  - Used percentage, not remaining percentage.
  - An absolute reset time. See
    `docs/claude-oauth-refresh-and-usage-ui.md` for the precision rules.
  - A native SwiftUI `ProgressView` bar, tinted by `Double.quotaTint` so a bar
    near its limit reads differently from an idle one. Colour reinforces the
    percentage text and is never the only channel carrying the value.
- The window and the menu bar use different layouts on purpose: a 360-point
  popover and a full-width pane do not want the same one. The window uses the
  `Form`; the menu bar uses the compact `UsageLimitsGrid`. What must not drift is
  the *wording*, which lives on `UsageLimitDisplay` (`percentageText`,
  `resetLabel(for:)`) — put any new user-facing string there, not in a view.
- Unavailable states are `ContentUnavailableView` with a Refresh action, never a
  bare headline-plus-body stack.
- The updated timestamp is static for a given query result. It updates only when
  a refresh succeeds or fails with a new `queriedAt` value.
- Manual refresh lives in the top toolbar, not inside the content card.
- Auto refresh runs every 30 seconds by default.
- Claude Code auto refresh uses a 60-second cadence because its OAuth usage
  endpoint rate-limits more aggressive polling.
- Xcode previews must not run live credential or network queries.

The menu-bar companion follows the same usage semantics in a compact format:

- The menu-bar item is a SwiftUI `MenuBarExtra` with `.window` style.
- Closing the main window keeps the process alive as a menu-bar companion and
  hides the Dock icon until **Open BorderCollie** or a Dock reopen restores it.
- The popup queries on open and refreshes every 30 seconds while visible.
- Claude Code network calls inside that loop are gated to about once every
  60 seconds and back off for at least five minutes after HTTP 429.
- A compact row is shown for each tracked agent, ordered `Codex`, then
  `Cursor`, then `Claude Code`.
- Codex compact format: `5h: 20% | 7d: 10%`.
- Cursor compact format: `Auto: 5% | API: 40%`.
- Claude Code compact format: `5h: 48% | 7d: 64%`.
- Compact percentages are usage consumed, rounded to whole percentages.
- Missing compact tiers show `--`.
- Detailed menu-bar UI and row-state rules live in
  `docs/menubar-item-design.me`.

The live-quota UI is implemented in:

- `BorderCollie/ContentView.swift` — sidebar destination.
- `BorderCollie/LiveQuotaView.swift` — the page, the `LiveQuotaTracker`
  descriptors, and each tracker's `UsageTrackerCopy`.
- `BorderCollie/CodexUsageDisplay.swift`, `CursorUsageDisplay.swift`,
  `ClaudeUsageDisplay.swift` — per-provider row labels and limit mapping.

## Architecture Overview

The current tracker implementation has six layers:

1. **Root navigation**
   - `ContentView` owns sidebar selection.
   - `Live quota` is one stable sidebar destination for every tracker.

2. **Tracker view**
   - `LiveQuotaView` owns page layout, the toolbar refresh that fans out to
     every tracker, preview safety, and one refresh loop per tracker at that
     tracker's cadence.
   - `LiveQuotaTracker` carries a provider's identity, service, limit mapping,
     cadence, and copy. Adding a tracker means adding a descriptor and a section,
     not a new page.
   - The view does not parse provider responses and does not read credentials.

3. **View model**
   - `UsageTrackerViewModel` owns loading state and the latest
     `SubscriptionQuota`.
   - It prevents overlapping refreshes with `guard !isLoading`.
   - It wraps the whole refresh operation in a 20-second timeout.

4. **Menu-bar companion**
   - `AgentUsageMenuBarView` renders the compact popup.
   - `MenuBarUsageViewModel` refreshes all configured agents concurrently,
     prevents overlapping refreshes, and maps each provider result into an
     independent row state.
   - `UsageQuotaQuery` provides the shared 20-second timeout wrapper used by
     both tracker pages and menu-bar rows.

5. **Quota service**
   - Provider services coordinate credential lookup and quota querying.
   - It converts credential states into normalized `SubscriptionQuota` errors.

6. **Provider-specific resolver/client**
   - `CodexCredentialResolver` reads Codex credentials from Keychain first and
     then `~/.codex/auth.json`.
   - `CodexUsageClient` queries the Codex quota endpoint and maps the response
     into normalized tiers.

Future trackers should follow this layering even if their implementation files
are initially provider-specific.

## Normalized Data Model

The shared normalized model lives in `CodexUsageModels.swift` today. Some names
remain Codex-oriented from the first tracker, but the shapes are shared by
Codex, Cursor, and Claude Code.

### `CredentialStatus`

Represents the state of local credentials:

- `valid`: credentials exist and can be used.
- `expired`: credentials exist but likely need refresh or login.
- `notFound`: credentials were not found.
- `parseError`: credentials or local data could not be parsed.

### `QuotaTier`

Represents one quota window:

- `name`: normalized window identifier, such as `five_hour` or `seven_day`.
- `utilization`: provider-reported used percentage, where `80` means 80% used.
- `resetsAt`: reset timestamp as an ISO 8601 string when available.

Important: `utilization` stores used percentage, not remaining percentage. The
display layer clamps and renders it directly.

### `SubscriptionQuota`

Represents the result of a tracker query:

- `tool`: tracker identifier, such as `codex`.
- `credentialStatus`: local credential state.
- `credentialMessage`: optional credential detail for error handling.
- `success`: true only when quota data was successfully fetched and parsed.
- `tiers`: normalized quota windows.
- `extraUsage`: reserved for tracker-specific supplemental data.
- `error`: user-readable query or parsing failure.
- `queriedAt`: Unix epoch milliseconds. The UI uses this for the static
  "Updated at" timestamp.

## Current Codex Implementation

### Credential Resolution

Codex credential lookup is implemented in `CodexCredentialResolver`.

Current lookup order:

1. macOS Keychain generic password named `Codex Auth`.
2. `~/.codex/auth.json`.

Current safety rules:

- Keychain lookup uses `/usr/bin/security`.
- Keychain lookup has a 2-second timeout.
- Tokens are parsed and retained only in service/client layers.
- Tokens are never passed to SwiftUI views.
- Non-ChatGPT auth mode is treated as `notFound`.
- Missing tokens are treated as `parseError`.
- Tokens older than 8 days are marked `expired`, but the service may still try
  a remote query before showing an expired-token error.

### Remote Query

Codex usage is fetched by `CodexUsageClient`.

Current endpoint:

```text
https://chatgpt.com/backend-api/wham/usage
```

Current request behavior:

- Method: `GET`
- Timeout: 15 seconds.
- Headers:
  - `Authorization: Bearer <access_token>`
  - `User-Agent: codex-cli`
  - `Accept: application/json`
  - `ChatGPT-Account-Id: <account_id>` when available

Current response mapping:

- `rate_limit.primary_window` and `rate_limit.secondary_window` become
  `QuotaTier` values.
- `used_percent` maps directly to `QuotaTier.utilization`.
- `limit_window_seconds` maps to `QuotaTier.name`.
- `reset_at` maps to ISO 8601 `QuotaTier.resetsAt`.

Known Codex windows:

| Remote seconds | Tier name | UI label |
| --- | --- | --- |
| `18000` | `five_hour` | `5h` |
| `604800` | `seven_day` | `7d` |

The compact menu-bar labels are `5h` and `7d`.

Unknown windows should be normalized using the current generic naming rule:

- `<n>_hour` for windows under 24 hours.
- `<n>_day` for windows of 24 hours or more.

## Current Cursor Implementation

### Credential Resolution

Cursor credential lookup is implemented in `CursorCredentialResolver`.

Current lookup:

1. `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
2. `ItemTable` key `cursorAuth/accessToken`.

Current safety rules:

- SQLite lookup uses `/usr/bin/sqlite3`.
- SQLite lookup has a 2-second timeout.
- Tokens are retained only in service/client layers.
- Tokens are never passed to SwiftUI views.
- Missing or empty tokens are treated as `notFound`.
- SQLite read failures are treated as `parseError`.

### Remote Query

Cursor usage is fetched by `CursorUsageClient`.

Current endpoint:

```text
https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
```

Current request behavior:

- Method: `POST`
- Body: `{}`
- Timeout: 15 seconds.
- Headers:
  - `Authorization: Bearer <cursorAuth/accessToken>`
  - `Content-Type: application/json`
  - `Accept: application/json`
  - `Connect-Protocol-Version: 1`
  - `User-Agent: Cursor`

Current response mapping:

- `planUsage.autoPercentUsed` becomes `cursor_auto_composer`.
- `planUsage.apiPercentUsed` becomes `cursor_api`.
- `billingCycleEnd` maps to each tier reset timestamp.
- Cursor reports current monthly used percentages; display renders them as
  consumed usage.

Known Cursor windows:

| Tier name | UI label |
| --- | --- |
| `cursor_auto_composer` | `Auto + Composer` |
| `cursor_api` | `API` |

The compact menu-bar labels are `Auto` and `API`.

### Refresh Behavior

Refresh behavior is split between the view and view model:

- `LiveQuotaView` starts every tracker's refresh automatically on page open.
- `LiveQuotaView` runs one loop per tracker at that tracker's own cadence —
  30 seconds for Codex and Cursor, 60 for Claude Code — so a slow provider
  cannot delay its neighbours' polls.
- `LiveQuotaView` disables auto refresh in Xcode previews.
- `UsageTrackerViewModel` ignores refresh requests while `isLoading` is true.
- `UsageTrackerViewModel` times out the full refresh operation after 20 seconds.
- The toolbar refresh button refreshes every tracker and remains available for
  manual recovery; a failing tracker also offers an inline Refresh.
- `MenuBarUsageViewModel` refreshes all tracked agents concurrently, ignores
  overlapping refresh requests, and keeps previous row data visible while a
  refresh is in flight.

This combination prevents the old "query runs forever" failure mode while still
making the feature automatic for normal use.

- Claude Code uses a 60-second page auto-refresh interval and a shared
  request gate so menu-bar 30-second ticks do not create a network call every
  cycle.

## Current Claude Code Implementation

### Credential Resolution

Claude Code credential lookup is implemented in `ClaudeCredentialResolver`.

Current lookup order:

1. macOS Keychain generic password named `Claude Code-credentials`.
2. `~/.claude/.credentials.json`, or `$CLAUDE_CONFIG_DIR/.credentials.json` when
   set.

Current safety rules:

- Keychain lookup uses `/usr/bin/security`.
- Keychain lookup has a 2-second timeout.
- Tokens are parsed and retained only in service/client layers.
- Tokens are never passed to SwiftUI views.
- Missing `claudeAiOauth` is treated as `notFound`.
- Missing or empty access tokens are treated as `parseError`.
- Tokens past `expiresAt` are marked `expired`, but the service may still try a
  remote query before showing an expired-token error.

### Remote Query

Claude Code usage is fetched by `ClaudeUsageClient`.

Current endpoint:

```text
https://api.anthropic.com/api/oauth/usage
```

Current request behavior:

- Method: `GET`
- Timeout: 15 seconds.
- Headers:
  - `Authorization: Bearer <access_token>`
  - `Accept: application/json`
  - `Content-Type: application/json`
  - `User-Agent: claude-code/2.1.220`
  - `anthropic-beta: oauth-2025-04-20`

Current response mapping:

- `five_hour` becomes `five_hour`.
- `seven_day` becomes `seven_day`.
- `utilization` maps directly to `QuotaTier.utilization`.
- `resets_at` is normalized to ISO 8601 without fractional seconds when parsing
  succeeds.

Known Claude Code windows:

| Tier name | UI label |
| --- | --- |
| `five_hour` | `5h` |
| `seven_day` | `7d` |

The compact menu-bar labels are `5h` and `7d`.


### Refresh And Rate Limiting

Claude Code is the exception to the default 30-second product cadence:

- The Claude Code detail page auto-refreshes every 60 seconds.
- `ClaudeUsageRequestGate` shares one process-wide cache/cooldown across the
  detail page and menu-bar popup.
- Successful quota responses are reused for at least 60 seconds.
- HTTP 429 starts a cooldown of at least 300 seconds. A positive `Retry-After`
  header may extend that cooldown; `Retry-After: 0` is ignored.
- While rate-limited, the gate prefers the last successful quota over a hard
  error so the UI does not flap.

## Reusable Parts

These parts should be reused for future trackers as-is or extracted into shared
types when the second tracker is implemented.

### UI Pattern

Reuse the current tracker detail pattern:

- Tracker name as `navigationTitle`, not as a heading in the body.
- Toolbar refresh button with `arrow.clockwise`, swapping to a `ProgressView`
  while the query is in flight.
- Fixed 30-second auto refresh loop.
- Grouped `Form` showing consumed percentages, filling the pane.
- Native `ProgressView` bars, threshold-tinted.
- Static `Updated at <time>` timestamp in the section footer.
- Every radius, spacing value, and metric font from `UsageDesign`; no new
  literals.
- Preview with mock quota data and auto refresh disabled.

For the menu bar, reuse the compact companion pattern:

- `MenuBarExtra` with the `MenuBarIcon` asset as a template image.
- `.menuBarExtraStyle(.window)` for room to show row states.
- One compact row per tracker.
- Provider-specific compact formatter functions near each provider's display
  helpers.

### Display Semantics

Reuse these rules:

- Show used percentage.
- Store used percentage in the data model.
- Clamp used percentage to `0...100`.
- Use monospaced digits for percentages and reset values.
- Show absolute reset times, never countdowns: a countdown is correct only at
  the instant it renders.
- Choose reset precision by distance to the reset, not by window length. One
  rule in `UsageResetFormatting` covers every tracker; do not add per-window
  formatting styles.
- Do not show credential details in any user-facing string.
- Compact menu-bar summaries should use whole-number used percentages.
- Numbers that change on refresh use `.contentTransition(.numericText())`.

### View Model Behavior

Reuse these rules:

- A refresh request should be ignored while a refresh is already in progress.
- Refresh should always clear `isLoading`, including timeout and failure paths.
- A full query should have an overall timeout.
- Query results should update the view through a normalized quota object.
- Preview initialization should support injecting sample quota data.
- Menu-bar refresh should keep previous row text visible while a new refresh is
  in progress.

### Test Structure

Reuse the current testing style:

- Unit tests for response normalization.
- Unit tests for credential parsing.
- Unit tests for display clamping and formatting of used percentage.
- Tests for reset formatting.
- Tests for compact menu-bar summary strings and row-state mapping.
- Capturing fake HTTP clients instead of real network calls.
- `xcodebuild build-for-testing` for non-launching verification.

## Provider-Specific Parts

Future trackers should vary only where the provider genuinely differs.

### Credential Discovery

Each tracker must define how credentials are discovered:

- Local auth file path.
- Keychain item name, if any.
- Environment variables, if appropriate.
- CLI command output, if appropriate.
- Token freshness rules.
- Required account/workspace/org identifiers.

Credential resolution should remain outside SwiftUI views.

### API Client

Each tracker must define:

- Endpoint or command to fetch usage.
- Required request headers.
- Timeout behavior.
- Status-code mapping.
- Response shape.
- Error body redaction rules.
- Whether quota is remote, local-only, or derived from log files.

### Response Normalization

Each tracker must map provider-specific usage into `SubscriptionQuota`.

Questions to answer for every tracker:

- Does the provider report used percentage or remaining percentage?
- Are reset times absolute timestamps, relative durations, or absent?
- Are there multiple quota windows?
- Are windows named by seconds, plan names, model names, or product features?
- Is usage scoped to user, team, organization, machine, or project?
- Does the provider expose hard quota, soft quota, or only current burn rate?

### UI Labels

Tracker-specific display labels may differ, but the display layout should not.

Examples:

- Codex and Claude Code use `5h` and `7d`.
- A future tracker may use labels like `Daily`, `Monthly`, `Requests`, or
  `Credits`, depending on the provider contract.

Prefer short labels that fit in one row.

## Shared Tracker Abstraction

The second tracker introduced the small shared abstraction below instead of
duplicating Codex-specific files with only names changed.

Recommended shared types:

```swift
protocol UsageTrackingService: Sendable {
    var toolID: String { get }
    func getSubscriptionQuota() async -> SubscriptionQuota
}

struct UsageTrackerDescriptor: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
}
```

Shared page:

- `LiveQuotaView`
  - Renders one `Section` per `LiveQuotaTracker`, each backed by its own
    `UsageTrackerViewModel`.
  - Owns the fan-out toolbar refresh and one auto-refresh loop per tracker.

Recommended shared view model:

- `UsageTrackerViewModel`
  - Stores `SubscriptionQuota?`.
  - Stores `isLoading`.
  - Calls a `UsageTrackingService`.
  - Preserves the current timeout and overlap prevention behavior.

Then Codex becomes one provider implementation:

- `CodexCredentialResolver`
- `CodexUsageClient`
- `CodexUsageService`
- `CodexUsageDisplayPolicy`, if Codex-specific labels remain separate

Keep future tracker work inside this abstraction unless a provider genuinely
needs a different user experience.

## Steps To Add A New Tracker

1. **Research the provider contract**
   - Identify where usage data comes from.
   - Identify credential storage.
   - Identify quota windows, reset behavior, and units.

2. **Define the provider resolver**
   - Add a credential resolver that returns a provider credential state.
   - Keep token parsing and storage paths testable through injected closures or
     file URLs.

3. **Define the provider client**
   - Add a client protocol for test injection.
   - Add a live implementation.
   - Set explicit request timeouts.
   - Redact or truncate error bodies.

4. **Normalize the result**
   - Convert provider data into `SubscriptionQuota`.
   - Preserve used-vs-remaining semantics clearly.
   - Set `queriedAt` only when the query actually ran.

5. **Add display policy**
   - Add window labels.
   - Reset formatting is shared and distance-based; a new tracker should not
     need its own rules.
   - Keep the row layout consistent.

6. **Wire it into the page**
   - Add a `LiveQuotaTracker` static with the provider's service, limit mapping,
     poll cadence, and `UsageTrackerCopy`.
   - Add it to `LiveQuotaTracker.all`, a `@StateObject` view model, a section,
     and an auto-refresh `.task` in `LiveQuotaView`.
   - Do not add a sidebar item or a detail route. Trackers are sections on one
     page.
   - Add a compact menu-bar descriptor and formatter.

7. **Add previews**
   - Add representative quota data to the `LiveQuotaView` preview.
   - Disable auto refresh in previews.

8. **Add tests**
   - Credential parse tests.
   - Successful response normalization test.
   - Unauthorized/expired mapping test.
   - Display conversion test.
   - Menu-bar compact formatter and row-state tests.
   - Timeout or no-overlap behavior test when practical.

9. **Verify**
   - Run `xcodebuild build-for-testing`.
   - Avoid app-hosted `xcodebuild test` until the scheme/test host is adjusted
     to avoid launching and hanging.

## Security And Privacy Standards

- Never hardcode access tokens, API keys, account IDs, or secrets.
- Never log bearer tokens.
- Never pass raw tokens into SwiftUI views.
- Prefer Keychain or provider-owned local auth files.
- Use explicit timeouts for subprocess, file, and network operations.
- Keep the app sandbox setting aligned with tracker requirements.
- If a tracker requires broad filesystem access, document why.
- If a tracker reads local logs, treat them as potentially sensitive.

## Error Handling Standards

Errors should be actionable but not noisy.

Happy path:

- Do not mention credentials or auth implementation details.
- Show usage bars and updated time.

Missing credentials:

- Show a concise message that the user should sign in to the provider CLI/app.

Expired credentials:

- Show a concise re-login message.

Network/API errors:

- Show a concise failure message.
- Keep manual toolbar refresh available.
- Do not expose long raw response bodies.

Timeout:

- Show `Quota query timed out. Try again in a moment.`

## Common Pitfalls

### Inverting provider-reported used percentage

Providers often report used percentage. The UI also shows used percentage, so
keep the model value and render it directly after clamping to `0...100`.

### Relative updated timestamps

SwiftUI relative date styles update continuously. The product standard is a
static updated time that changes only after refresh.

### Preview side effects

Previews must not read Keychain, read user auth files, or call remote endpoints.
Always inject preview quota data and disable auto refresh.

### Overlapping auto refresh

Auto refresh must not start a second query while one is still running. Keep the
view-model `isLoading` guard.

### App sandbox failures

Trackers may need access to user auth files, Keychain subprocesses, and network
requests. If sandbox settings change, retest credential lookup and remote query.

### App-hosted tests launching UI

The current Xcode test scheme may launch the macOS app for tests. Use
`build-for-testing` for safe compile verification unless the test host is
reconfigured.

## Current Verification Baseline

The current implementation has been verified with:

```sh
xcodebuild build-for-testing -project BorderCollie.xcodeproj -scheme BorderCollie -destination 'platform=macOS' -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild CODE_SIGNING_ALLOWED=NO
```

Use the same command after tracker changes unless you intentionally need a
runtime UI test.
