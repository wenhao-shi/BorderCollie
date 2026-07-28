# Usage Tracker Design

This document describes the design of BorderCollie's usage tracking feature and
the standards future trackers should follow. The current implementation tracks
Codex, Cursor, and Claude Code usage. Future trackers should preserve
the same user experience and normalized quota model while isolating each agent's
credential and API details.

For detailed menu-bar interaction and visual rules, read
`docs/menubar-item-design.me`.

## Goals

- Show usage remaining for each supported coding agent.
- Query automatically when a tracker page opens.
- Query automatically when the menu-bar usage popup opens.
- Refresh automatically on a fixed cadence without user configuration.
- Keep a manual toolbar refresh action for recovery and debugging.
- Keep a manual icon-only menu-bar refresh action for quick recovery.
- Normalize provider-specific quota APIs into one UI-friendly model.
- Keep credentials local and never expose tokens in SwiftUI views.
- Make adding a new tracker predictable, testable, and low-risk.

## Current Product Standard

The current Codex screen defines the product standard for future trackers:

- The sidebar contains one tab per tracker.
- The detail window header title is the tracker name, for example `Codex`.
- Do not repeat the tracker name as a large heading in the detail body.
- Auth implementation details are not shown during normal operation.
- The main section title is `Usage remaining`.
- Each usage window is shown as:
  - A human label, such as `5h` or `Weekly`.
  - Remaining percentage, not used percentage.
  - A reset indicator.
  - A native SwiftUI `ProgressView` bar.
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
  hides the Dock icon until **Show Window** or a Dock reopen restores it.
- The popup queries on open and refreshes every 30 seconds while visible.
- Claude Code network calls inside that loop are gated to about once every
  60 seconds and back off for at least five minutes after HTTP 429.
- A compact row is shown for each tracked agent, ordered `Codex`, then
  `Cursor`, then `Claude Code`.
- Codex compact format: `5h: 80% | 7d: 90%`.
- Cursor compact format: `Auto: 95% | API: 60%`.
- Claude Code compact format: `5h: 52% | 7d: 36%`.
- Compact percentages are usage remaining, rounded to whole percentages.
- Missing compact tiers show `--`.
- Detailed menu-bar UI and row-state rules live in
  `docs/menubar-item-design.me`.

The current Codex UI is implemented primarily in:

- `BorderCollie/ContentView.swift`
- `BorderCollie/CodexUsageView.swift`
- `BorderCollie/CodexUsageDisplay.swift`

Claude Code follows the same UI pattern via:

- `BorderCollie/ClaudeUsageView.swift`
- `BorderCollie/ClaudeUsageDisplay.swift`

## Architecture Overview

The current tracker implementation has six layers:

1. **Root navigation**
   - `ContentView` owns sidebar selection.
   - Each tracker should be a stable sidebar destination.

2. **Tracker view**
   - `UsageTrackerView` owns layout, toolbar refresh, preview safety, and the
     fixed 30-second refresh loop.
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
display layer converts it with `100 - utilization`.

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
| `604800` | `seven_day` | `Weekly` |

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
- Cursor reports current monthly used percentages; display still converts to
  remaining percentage.

Known Cursor windows:

| Tier name | UI label |
| --- | --- |
| `cursor_auto_composer` | `Auto + Composer` |
| `cursor_api` | `API` |

The compact menu-bar labels are `Auto` and `API`.

### Refresh Behavior

Refresh behavior is split between the view and view model:

- `CodexUsageView` starts refresh automatically on page open.
- `CodexUsageView` repeats refresh every 30 seconds.
- `CodexUsageView` disables auto refresh in Xcode previews.
- `UsageTrackerViewModel` ignores refresh requests while `isLoading` is true.
- `UsageTrackerViewModel` times out the full refresh operation after 20 seconds.
- The toolbar refresh button remains available for manual recovery.
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
| `seven_day` | `Weekly` |

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

- Title at the top of the detail view.
- Toolbar refresh button with `arrow.clockwise`.
- Fixed 30-second auto refresh loop.
- `Usage remaining` card.
- Native `ProgressView` bars.
- Static `Updated at <time>` timestamp.
- Preview with mock quota data and auto refresh disabled.

For the menu bar, reuse the compact companion pattern:

- `MenuBarExtra("BorderCollie", systemImage: "gauge")`.
- `.menuBarExtraStyle(.window)` for room to show row states.
- One compact row per tracker.
- Provider-specific compact formatter functions near each provider's display
  helpers.

### Display Semantics

Reuse these rules:

- Show remaining percentage.
- Store used percentage in the data model.
- Clamp remaining percentage to `0...100`.
- Use monospaced digits for percentages and reset values.
- Format short-window resets as time.
- Format weekly or longer resets as date.
- Do not show credential details in the happy path.
- Compact menu-bar summaries should use whole-number remaining percentages.

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
- Unit tests for display conversion from used percentage to remaining
  percentage.
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

- Codex uses `5h` and `Weekly`.
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

Recommended shared view:

- `UsageTrackerView`
  - Receives a tracker title and view model.
  - Renders the current usage card.
  - Owns toolbar refresh and 30-second auto refresh.

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
   - Add reset formatting rules if the default time/date split is not enough.
   - Keep the card layout consistent.

6. **Wire navigation**
   - Add a sidebar item.
   - Add a detail route.
   - Keep one stable selection enum case per tracker.
   - Add a compact menu-bar descriptor and formatter.

7. **Add previews**
   - Add a filled preview with representative quota data.
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

### Treating used percentage as remaining percentage

Providers often report used percentage. The UI must show remaining percentage.
Keep the model as used percentage and convert only in the display layer.

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
