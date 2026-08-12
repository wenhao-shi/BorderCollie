# BorderCollie Project Guide

## Project Tech Stack And Environment

- App type: macOS SwiftUI app.
- Project format: Xcode project at `BorderCollie.xcodeproj`.
- Language: Swift.
- UI framework: SwiftUI with `NavigationSplitView` and native toolbars.
- Tests: Swift Testing in `BorderCollieTests`.
- Current deployment target: macOS 26.5.
- Current bundle identifier: `Alpard.BorderCollie`.
- App sandbox: disabled for the app target because trackers need access to
  local agent credentials, subprocess credential lookup, and network quota
  requests.

## Repository Layout

- `BorderCollie/BorderCollieApp.swift`: app entry point.
- `BorderCollie/AppDelegate.swift`: keep-alive + Dock/menu-bar activation policy.
- `BorderCollie/ContentView.swift`: root sidebar/detail navigation.
- `BorderCollie/AgentUsageMenuBarView.swift`: menu-bar usage popup UI.
- `BorderCollie/MenuBarUsageViewModel.swift`: menu-bar refresh orchestration,
  row state, and compact provider summaries.
- `BorderCollie/UsageQuotaQuery.swift`: shared timeout wrapper for quota
  queries.
- `BorderCollie/UsageTrackerView.swift`: shared tracker UI, toolbar refresh,
  auto-refresh loop, and preview-safe rendering.
- `BorderCollie/UsageTrackerViewModel.swift`: loading state, refresh lifecycle,
  timeout handling, and quota state.
- `BorderCollie/UsageTrackingService.swift`: shared tracker service and HTTP
  client protocols.
- `BorderCollie/CodexUsageView.swift`: Codex-specific tracker wrapper.
- `BorderCollie/CodexQuotaService.swift`: coordinates credentials and quota
  client.
- `BorderCollie/CodexCredentialResolver.swift`: Codex credential discovery and
  parsing.
- `BorderCollie/CodexUsageClient.swift`: Codex quota HTTP client and response
  normalization.
- `BorderCollie/CursorUsageView.swift`: Cursor-specific tracker wrapper.
- `BorderCollie/CursorQuotaService.swift`: coordinates Cursor credentials and
  quota client.
- `BorderCollie/CursorCredentialResolver.swift`: Cursor IDE auth-token
  discovery from Cursor's local `state.vscdb`.
- `BorderCollie/CursorUsageClient.swift`: Cursor current-period usage client
  and response normalization.
- `BorderCollie/ClaudeUsageView.swift`: Claude Code-specific tracker wrapper.
- `BorderCollie/ClaudeQuotaService.swift`: coordinates Claude Code credentials
  and quota client.
- `BorderCollie/ClaudeCredentialResolver.swift`: Claude Code OAuth credential
  discovery from Keychain and `~/.claude/.credentials.json`.
- `BorderCollie/ClaudeUsageRequestGate.swift`: shared Claude usage cache and 429 cooldown.
- `BorderCollie/ClaudeUsageClient.swift`: Claude Code OAuth usage client and
  response normalization.
- `BorderCollie/CodexUsageModels.swift`: normalized quota models and shared
  formatting helpers.
- `BorderCollie/CodexUsageDisplay.swift`: display-policy helpers for usage
  rows.
- `BorderCollie/CursorUsageDisplay.swift`: Cursor monthly usage row labels.
- `BorderCollie/ClaudeUsageDisplay.swift`: Claude Code session/weekly usage
  row labels.
- `docs/tracker_design.md`: design guide for adding future usage trackers.
- `docs/menubar-item-design.me`: design contract for the menu-bar companion
  surface.

## Common Commands

Use this for non-launching compile verification:

```sh
xcodebuild build-for-testing -project BorderCollie.xcodeproj -scheme BorderCollie -destination 'platform=macOS' -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild CODE_SIGNING_ALLOWED=NO
```

Avoid direct app-hosted `xcodebuild test` unless you specifically need it and
are prepared for the app UI to launch.

## Current Usage Tracker Standard

- Query automatically when a tracker page opens.
- Query automatically when the menu-bar usage popup opens.
- Closing the main window keeps the gauge menu-bar item alive and hides the Dock icon.
- Refresh automatically every 30 seconds by default; Claude Code uses
  a 60-second cadence plus a shared 429/cache gate.
- Keep manual Refresh in the top toolbar.
- Keep manual refresh in the menu-bar popup as an icon-only button.
- Show usage consumed in percentages and progress bars.
- The menu-bar popup shows all tracked agents in compact used format:
  `Codex 5h: 20% | 7d: 10%`, `Cursor Auto: 5% | API: 40%`, and
  `Claude Code 5h: 48% | 7d: 64%`.
- Use native SwiftUI `ProgressView` bars.
- Keep updated time static until the next refresh.
- Do not show auth implementation details in the happy path.
- Disable live refresh/network behavior in previews.

## Common Errors And Pitfalls

### Symptom: app UI pops up or test command hangs

- Root cause: app-hosted macOS tests can launch the app process.
- Fix: use `xcodebuild build-for-testing` for compile verification.
- Prevention: keep model/client logic unit-testable and avoid requiring full app
  launches for basic checks.

### Symptom: Codex query spins forever

- Root cause: missing timeout, blocking credential lookup, or overlapping
  refreshes.
- Fix: preserve the Keychain timeout, HTTP timeout, full refresh timeout, and
  `isLoading` guard.
- Prevention: future trackers must use explicit timeouts for file, subprocess,
  and network work.

### Symptom: preview tries to query real credentials or network

- Root cause: preview instantiated the live view model and auto-refresh loop.
- Fix: inject sample quota data and pass `runsAutoRefresh: false`.
- Prevention: every tracker and menu-bar preview should use local sample data
  only.

### Symptom: `#Preview` macro fails in sandboxed command-line build

- Root cause: Swift preview macro plugin server can fail under the sandbox.
- Fix: use `PreviewProvider`.
- Prevention: prefer `PreviewProvider` in this project until the macro-server
  environment is known to be stable.


### Symptom: Claude Code tracker returns HTTP 429 after frequent refresh

- Root cause: Anthropic's `/api/oauth/usage` endpoint rate-limits aggressive
  polling; BorderCollie's default 30-second cadence is too fast for Claude.
- Fix: keep Claude page auto-refresh at 60 seconds and let
  `ClaudeUsageRequestGate` cache successes and cool down for at least
  300 seconds after 429.
- Prevention: do not poll the Claude OAuth usage endpoint more often than
  about once every 60 seconds across the app window and menu bar.

### Symptom: usage percentage appears inverted

- Root cause: display code subtracts a provider-reported used percentage from
  100, turning it into remaining percentage.
- Fix: store provider value as `QuotaTier.utilization`, clamp it to `0...100`,
  and render it directly.
- Prevention: document each provider's percentage semantics before normalizing.

### Symptom: "Updated" time changes every second

- Root cause: using relative date display.
- Fix: show a static time based on `queriedAt`.
- Prevention: updated timestamps should change only when refresh produces a new
  query result.

### Symptom: credential lookup fails after re-enabling sandbox

- Root cause: sandbox restrictions block user auth files, local Cursor state,
  Keychain/sqlite subprocesses, or network access.
- Fix: keep sandbox disabled or add an explicit entitlement strategy.
- Prevention: retest Keychain, `~/.codex/auth.json`, Cursor `state.vscdb`,
  Claude Code Keychain/`~/.claude/.credentials.json`, and remote usage calls
  when changing signing or sandbox settings.

### Symptom: Cursor tracker shows missing credentials while Cursor is signed in

- Root cause: Cursor moved or renamed its local auth database, or the
  `cursorAuth/accessToken` key is absent.
- Fix: inspect `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  and update `CursorCredentialResolver` if Cursor changed storage layout.
- Prevention: keep Cursor credential lookup isolated and covered by resolver
  tests.

## Key Technical Decision Records

### Decision: normalize tracker output into `SubscriptionQuota`

- Context: different agents may expose usage through different APIs, files, or
  CLI commands.
- Alternatives considered: render each provider response directly in SwiftUI.
- Rationale: one normalized model keeps UI consistent and makes future tracker
  additions testable.

### Decision: show provider-reported used percentage

- Context: Codex and Cursor report used percentage, and Claude reports
  utilization with the same meaning.
- Alternatives considered: convert used percentage to remaining percentage in
  the display layer.
- Rationale: rendering the normalized utilization directly keeps bars and
  labels aligned with provider semantics.

### Decision: fixed 30-second auto refresh

- Context: the user should not need to click Refresh during normal operation.
- Alternatives considered: user-selectable 5s, 30s, or 1m cadence.
- Rationale: a fixed cadence keeps the UI simpler and avoids unnecessary
  provider polling choices.


### Decision: Claude Code uses a slower refresh and shared request gate

- Context: Claude Code's OAuth usage endpoint returns HTTP 429 under the
  shared 30-second auto-refresh cadence.
- Alternatives considered: keep a 300-second page cadence, slow every tracker,
  or keep 30 seconds and surface 429 errors.
- Rationale: Codex and Cursor tolerate 30-second polling; Claude uses a
  60-second page cadence plus a process-wide cache and ≥300-second 429
  cooldown so the menu-bar loop does not burn the token budget.


### Decision: manual refresh belongs in the toolbar

- Context: manual refresh is a fallback action, not content.
- Alternatives considered: place Refresh inside the detail page header.
- Rationale: toolbar placement is more native for a macOS command and keeps the
  page focused on usage data.

### Decision: disable live auto refresh in previews

- Context: previews should be fast, deterministic, and safe.
- Alternatives considered: let previews use the live view model.
- Rationale: live previews would read local credentials and call remote APIs.

### Decision: use `build-for-testing` as the default verification command

- Context: direct app-hosted tests launched the UI and could hang after
  assertions passed.
- Alternatives considered: run full `xcodebuild test` after every change.
- Rationale: `build-for-testing` catches compile errors without disrupting the
  desktop session.

### Decision: extract a shared tracker view and view model

- Context: Cursor is the second tracker and shares Codex's refresh, timeout,
  toolbar, preview, and usage-card behavior.
- Alternatives considered: duplicate the Codex view/model and rename files.
- Rationale: shared `UsageTrackerView` and `UsageTrackerViewModel` keep tracker
  behavior consistent while provider-specific credential and API details remain
  isolated.

### Decision: add a SwiftUI `MenuBarExtra` companion

- Context: usage should be visible without navigating the main window.
- Alternatives considered: AppKit `NSStatusItem` or replacing the regular app
  with a menu-bar-only utility.
- Rationale: `MenuBarExtra` with `.window` style preserves the existing Dock app
  while providing enough room for compact async usage rows.

### Decision: compact menu-bar summaries reuse normalized quota data

- Context: the menu-bar popup needs all tracked agents in a short format.
- Alternatives considered: provider-specific menu calls or rendering the full
  tracker cards in miniature.
- Rationale: compact formatters keep provider labels short while sharing the
  same credential, timeout, and percentage-normalization behavior as the main
  tracker views.

### Decision: Cursor uses IDE auth plus current-period dashboard usage

- Context: Cursor CLI/agent exposes auth and model commands but not the monthly
  split shown in the usage dashboard. Cursor IDE stores an access token in local
  state, and `DashboardService/GetCurrentPeriodUsage` returns the monthly
  `Auto + Composer` and `API` usage percentages plus billing-cycle reset.
- Alternatives considered: scrape UI/dashboard HTML, call Cursor CLI, or require
  a team Admin API key.
- Rationale: the IDE-token dashboard call matches the personal Pro+ dashboard
  with no extra setup; the Admin API is better for teams but not the least
  friction path for this app.


### Decision: Claude Code uses Claude.ai OAuth usage

- Context: Claude Code stores Claude.ai OAuth credentials in the macOS Keychain
  item `Claude Code-credentials` (with `~/.claude/.credentials.json` as a
  fallback), and Anthropic exposes session/weekly utilization through
  `GET /api/oauth/usage`.
- Alternatives considered: scrape claude.ai cookies/session keys, parse local
  JSONL session logs, or require an Anthropic Console Admin API key.
- Rationale: the Claude Code OAuth token plus `/api/oauth/usage` matches the
  personal Pro/Max rate-limit windows with no extra setup and reuses the same
  used-percentage UX as Codex.

## Future Tracker Guidance

Read `docs/tracker_design.md` before adding another tracker.

Read `docs/menubar-item-design.me` before changing the menu-bar companion UI or
adding another tracker row there.

When adding future trackers, preserve:

- normalized quota model,
- 30-second auto refresh,
- toolbar refresh fallback,
- menu-bar refresh fallback,
- native usage bars,
- compact menu-bar summary rows,
- static updated timestamp,
- credential isolation outside SwiftUI,
- injected clients for tests,
- preview-only sample data.

## Maintenance Notes

- Do not commit credentials, auth files, tokens, or local DerivedData.
- Do not revert user UI tweaks without asking.
- Keep comments sparse and focused on non-obvious behavior.
- Update this file after significant architecture or workflow changes.
