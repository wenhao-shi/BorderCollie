# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read AGENTS.md first

`AGENTS.md` is the authoritative project guide: per-file map, product standards (refresh cadence, display rules), symptom→cause→fix pitfalls, and technical decision records. This file covers only what isn't there — verified commands and the cross-file architecture. When a *standard* or *decision* changes, update `AGENTS.md`, not this file.

Design docs are load-bearing, not background reading: `docs/tracker_design.md` before adding a tracker, `docs/menubar-item-design.me` before touching the menu-bar surface, `docs/usage-dashboard-design.md` before changing import, pricing, or aggregation semantics.

## Commands

Default compile verification — does not launch the app:

```sh
xcodebuild build-for-testing -project BorderCollie.xcodeproj -scheme BorderCollie \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Tests are Swift Testing in an app-hosted bundle (`TEST_HOST` = `BorderCollie.app`), so running them launches the app process. After `build-for-testing`:

```sh
# one test — the trailing () is REQUIRED
xcodebuild test-without-building -project BorderCollie.xcodeproj -scheme BorderCollie \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:BorderCollieTests/UsageDashboardTests/pricingUsesEffectiveRuleCacheClassesAndLongContextModifier\(\)

# one suite (no parens) — BorderCollieTests or UsageDashboardTests
-only-testing:BorderCollieTests/UsageDashboardTests
```

Trap: dropping the `()` on a single-test identifier makes xcodebuild run **zero** tests and still print `** TEST EXECUTE SUCCEEDED **`. Confirm with `xcrun xcresulttool get test-results summary --path <xcresult>` that `totalTestCount` is non-zero before believing a green run.

Never run the bare test action (`-only-testing` omitted) casually: it pulls in `BorderCollieUITests`, which drives the real UI. The app also stays resident after its last window closes (`BorderCollie/AppDelegate.swift:7` switches to `.accessory` rather than terminating), so a launched host can linger in the menu bar.

## Architecture: two independent subsystems

They share the SwiftUI shell (`ContentView.swift` sidebar) and nothing else. Do not join them — different data models, different refresh lifecycles, different privacy rules.

**1. Live subscription quota** (polled, ephemeral, no persistence)

```
UsageTrackerView / AgentUsageMenuBarView
  → UsageTrackerViewModel / MenuBarUsageViewModel   (@MainActor, isLoading guard)
  → UsageQuotaQuery.query(service:timeout:)         (20s cap, UsageQuotaQuery.swift:10)
  → {Codex,Cursor,Claude}QuotaService
  → *CredentialResolver + *UsageClient              → SubscriptionQuota
```

Every provider normalizes to `SubscriptionQuota` / `QuotaTier.utilization` (provider-reported **consumed** percent). The window and the menu bar are separate view models over the same services, so a provider gets polled twice — which is why Claude's throttle lives in a process-wide actor, `ClaudeUsageRequestGate` (`ClaudeUsageRequestGate.swift:12-13`: 60s minimum interval, ≥300s cooldown after 429) rather than in either view model. Adding a rate-limited provider means adding a gate, not slowing a timer.

**2. Historical usage analytics** (`BorderCollie/UsageDashboard/`, imported, persisted, local SQLite)

```
{ClaudeCode,Codex,OpenCode,Pi}UsageImporter   incremental, checkpointed by byte offset
  → UsageAnalyticsStore                        actor over SQLite, schemaVersion 3
  → UsageAnalyticsBackend.refresh()            import → price everything → aggregate
  → UsageAggregator                            → UsageAggregate
  → UsageDashboardModel / EvaluationRunsModel  @MainActor
```

DB: `~/Library/Application Support/BorderCollie/usage-analytics.sqlite3` (0700 dir / 0600 file, WAL). Delete it to force a full re-import; checkpoints live in the same file.

Two properties worth knowing before changing this layer:

- `UsageAnalyticsBackend.refresh()` reprices **every event in the store**, not just newly imported ones (`UsageAnalyticsBackend.swift:375-377` calls `store.events()` with no interval). Cost is O(total history) per refresh, which is why refresh is user/screen-driven and never joins the 30-second quota loop.
- Importers are per-source and fail independently — an importer error is captured as a `UsageImportIssue` in the report and the other agents still commit (`UsageAnalyticsBackend.swift:358-372`). A single corrupt session file should never take down the dashboard.

## Test and preview seams

Everything provider-touching or disk-touching is injectable; use these rather than mocking at the view layer.

- Network: `UsageHTTPClient` protocol (`UsageTrackingService.swift:9`) — pass a stub returning `(Data, HTTPURLResponse)`.
- Store: `UsageAnalyticsStore(databaseURL:)` — point at a temp dir; never let a test open the default path.
- Pipeline: `UsageAnalyticsBackend(importers:)` — inject synthetic importers.
- Importer source roots are env-overridable (`UsageImporters.swift:4-27`), which is how you point a real importer at fixtures: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_DATA_HOME` (OpenCode), `PI_CODING_AGENT_DIR`.
- Previews: use `PreviewProvider`, not the `#Preview` macro (the macro plugin server fails under the sandboxed CLI build). Inject sample quota/aggregates and `runsAutoRefresh: false`; a preview must never read credentials, hit the network, or open the analytics store.

## Project constraints

`SWIFT_VERSION = 5.0` (Swift 5 language mode despite the actor/`Sendable` style), `MACOSX_DEPLOYMENT_TARGET = 26.5`, `ENABLE_APP_SANDBOX = NO` on the app target — trackers need Keychain, `~/.codex/auth.json`, Cursor's `state.vscdb`, and network access. There is no shared `.xcscheme` in `xcshareddata`; `xcodebuild` autocreates the `BorderCollie` scheme.
