# BorderCollie

BorderCollie is a native macOS SwiftUI app for monitoring coding-agent usage
limits from one local desktop surface. It currently tracks Codex, Cursor, and
Claude Code, showing consumed usage in the main window and a compact menu-bar
popup.

The app is local-first by design. Provider credentials are read from
provider-owned local auth state, used only by provider-specific service/client
layers, and never passed into SwiftUI views.

## Features

- Native macOS app with a sidebar for Codex, Cursor, and Claude Code trackers.
- Agent brand icons in the sidebar, main window, and menu-bar popup.
- Automatic Claude Code OAuth token refresh, so a stale access token recovers
  without re-running the CLI.
- Menu-bar item with compact usage rows for all tracked agents.
- Automatic query when a tracker page or menu-bar popup opens.
- Fixed 30-second auto refresh across tracker pages and the menu-bar popup.
- Manual toolbar refresh in tracker pages.
- Icon-only manual refresh in the menu-bar popup.
- Usage consumed display for percentages and progress bars.
- Static updated timestamp that changes only after a new query result.
- Preview-safe SwiftUI surfaces that do not read credentials or call networks.
- Swift Testing coverage for credential parsing, API normalization, display
  formatting, compact menu-bar summaries, and failure mapping.
- A local historical usage dashboard for Claude Code, Codex, OpenCode, and Pi
  with rolling 24-hour, 7-day, and 30-day periods, hourly/daily token and cost
  charts, normalized metrics, and detailed model/day token breakdowns.

## Supported Trackers

### Codex

Codex usage is fetched from:

```text
https://chatgpt.com/backend-api/wham/usage
```

Credential lookup order:

1. macOS Keychain generic password named `Codex Auth`.
2. `~/.codex/auth.json`.

The main window displays normalized 5-hour and weekly quota windows. The
menu-bar compact format is:

```text
5h: 20% | 7d: 10%
```

### Cursor

Cursor usage is fetched from:

```text
https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
```

Credential lookup:

1. `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
2. `ItemTable` key `cursorAuth/accessToken`.

The main window displays current monthly `Auto + Composer` and `API` consumed
usage. The menu-bar compact format is:

```text
Auto: 5% | API: 40%
```

## Architecture

BorderCollie keeps provider-specific credential and network work outside the
SwiftUI layer.

```text
SwiftUI views
  UsageTrackerView
  AgentUsageMenuBarView

State and refresh orchestration
  UsageTrackerViewModel
  MenuBarUsageViewModel
  UsageQuotaQuery

Provider services
  CodexQuotaService
  CursorQuotaService

Credential and API clients
  CodexCredentialResolver
  CodexUsageClient
  CursorCredentialResolver
  CursorUsageClient

Historical analytics backend (separate from subscription quota)
  UsageAnalyticsBackend
  UsageAnalyticsStore
  ClaudeCodeUsageImporter / CodexUsageImporter
  OpenCodeUsageImporter / PiUsageImporter
  UsagePricingEngine / UsageAggregator

Historical analytics UI
  UsageDashboardModel / UsageDashboardView
  UsageDailyChart / UsageMetricStrip / UsageBreakdownTable
```

Provider responses are normalized into `SubscriptionQuota`. `QuotaTier`
preserves provider-reported used percentage in `utilization`; display code
clamps it to the `0...100` range before rendering it.

## Privacy And Security

BorderCollie reads local provider auth state so it can query the same usage data
visible in provider apps or dashboards. It does not hardcode tokens, store
copied tokens, or render tokens in UI.

Security boundaries to preserve:

- Credential discovery stays outside SwiftUI views.
- Bearer tokens are used only by provider-specific clients.
- Network, subprocess, and full-refresh work use explicit timeouts.
- Provider error bodies are truncated before display.
- Xcode previews use sample data only.

The app target currently has the macOS app sandbox disabled because the trackers
need local auth-file access, subprocess credential lookup, and remote quota
requests. If sandboxing is re-enabled, retest Keychain access, Cursor SQLite
access, Codex auth-file access, and network calls.

## Requirements

- macOS 26.5 or newer target SDK/runtime.
- Xcode 26.6 or a compatible version for the current project format.
- A signed-in Codex CLI or Cursor install for live tracker data.

## Build And Verify

Open `BorderCollie.xcodeproj` in Xcode and run the `BorderCollie` scheme.

For non-launching command-line verification, use:

```sh
xcodebuild build-for-testing \
  -project BorderCollie.xcodeproj \
  -scheme BorderCollie \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Avoid direct app-hosted `xcodebuild test` unless you specifically need it and
are prepared for the app UI to launch.

## Project Layout

```text
BorderCollie/
  BorderCollieApp.swift          App entry point and scenes
  ContentView.swift              Root sidebar/detail navigation
  UsageTrackerView.swift         Shared tracker page UI
  UsageTrackerViewModel.swift    Page refresh lifecycle
  AgentUsageMenuBarView.swift    Menu-bar popup UI
  MenuBarUsageViewModel.swift    Menu-bar row refresh orchestration
  UsageQuotaQuery.swift          Shared full-query timeout wrapper
  UsageTrackingService.swift     Shared service and HTTP protocols
  Codex*.swift                   Codex credential, API, display, and view code
  Cursor*.swift                  Cursor credential, API, display, and view code
  UsageDashboard/                Historical import, pricing, aggregation, and UI
BorderCollieTests/
  BorderCollieTests.swift        Swift Testing coverage
  UsageDashboardTests.swift      Synthetic historical-backend coverage
docs/
  tracker_design.md              Architecture guide for adding trackers
  menubar-item-design.me         Menu-bar item interaction and UI design
  usage-dashboard-design.md      Historical accounting contract
  usage-dashboard-plan.md        Staged dashboard delivery plan
```

## Documentation

- [Tracker design](docs/tracker_design.md): architecture, data model, provider
  integration, refresh behavior, and extension guidance.
- [Menu-bar item design](docs/menubar-item-design.me): menu-bar scene,
  compact row behavior, visual layout, and implementation contract.
- [Codex usage query report](docs/cc-switch-codex-usage-query-report.md):
  reference notes for the Codex usage API lineage.
- [Historical usage dashboard design](docs/usage-dashboard-design.md): local
  source contracts, normalization, privacy, pricing, and aggregation.
- [Historical usage dashboard plan](docs/usage-dashboard-plan.md): backend-first
  implementation gates followed by the deferred UI stage.

## Development Notes

- Keep provider credential lookup isolated from SwiftUI.
- Store provider-reported used percentage in `QuotaTier.utilization`; clamp and
  render it as consumed usage in display code.
- Keep auto refresh fixed at 30 seconds unless the product standard changes.
- Keep previews deterministic and offline.
- Add tests for new credential parsing, response normalization, display labels,
  menu-bar compact labels, and error mapping when adding another tracker.

Read `docs/tracker_design.md` before adding future trackers.

## License

BorderCollie is released under the MIT License. See `LICENSE` for details.
