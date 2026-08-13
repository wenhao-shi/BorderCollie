# Usage Tracker Worklog

This directory records the implementation trace for the historical usage
dashboard backend defined in:

- `docs/usage-dashboard-design.md`
- `docs/usage-dashboard-plan.md`

## Status

Backend and SwiftUI dashboard implementation complete. Automated verification
passes; interactive screenshot QA is blocked by ScreenCaptureKit in this session.

## Trace

### 2026-08-12 — Step 1: Worklog initialized

- Created `worklogs/usage_tracker` before implementation work as requested.
- Confirmed the implementation scope is backend-only: normalized accounting,
  persistence, Claude Code/Codex/OpenCode/Pi importers, effective-dated pricing,
  aggregation, and tests.
- No application behavior has been changed yet.

### 2026-08-12 — Step 2: Source contracts audited

- Confirmed the Xcode project uses synchronized filesystem groups, so new Swift
  files under `BorderCollie/` and `BorderCollieTests/` require no project-file edits.
- Inspected installed source shapes without copying message content into the repository:
  - Claude Code JSONL repeats streaming snapshots under stable message/request
    IDs and exposes separate 5-minute/1-hour cache-write counts.
  - Codex JSONL exposes request-level `last_token_usage`; input is inclusive of
    cached classifications, and model context arrives on preceding `turn_context` records.
  - OpenCode stores assistant accounting in its SQLite `message.data` JSON.
  - Pi stores assistant accounting under `message.usage`, with source cost as a
    per-bucket object whose `total` is retained.
- Confirmed SQLite3 is available through the macOS SDK.

### 2026-08-12 — Step 3: Normalized model and SQLite store

- Added the disjoint `in`, `cache-write`, `cache-read`, and `out` contract,
  optional reasoning subset, completeness state, provenance, scaled money, and
  checked arithmetic.
- Added actor-isolated SQLite schema version 2 for events, checkpoints, pricing
  rules, effective-dated model aliases, and a version-1 migration.
- Added atomic event/checkpoint application, idempotent event upsert, per-source
  reset/removal, catalog replacement, repricing, and indexed range reads.
- Source paths are represented by SHA-256 source keys; prompt/response/tool
  bodies and paths are not persisted.

### 2026-08-12 — Step 4: Four incremental importers

- Claude Code: parses assistant usage, preserves TTL cache-write buckets, and
  deduplicates repeated message IDs.
- Codex: parses only `last_token_usage`, carries the current model in checkpoint
  state, splits inclusive input, and retains partial older records when
  cache-write semantics are absent.
- OpenCode: opens its database read-only and advances an update-time high-water
  mark with boundary upserts.
- Pi: parses assistant usage and preserves provider, model, reasoning, and
  source-reported total cost.
- JSONL checkpoints stop before an incomplete trailing line and reset a single
  source on truncation, replacement, or importer-version change.

### 2026-08-12 — Step 5: Official effective-dated pricing

- Added official standard token rules for observed Claude Fable 5, Opus 5,
  Sonnet 5, Haiku 4.5, GPT-5.6 Sol/Terra/Luna, and GPT-5.5 models.
- Stored rates as integer USD nanodollars per token.
- Added Anthropic 5-minute/1-hour write pricing, OpenAI cache writes, exact
  Sonnet 5 introductory/standard boundary, and OpenAI >272K input multipliers.
- Unknown OpenCode gateway models and `codex-auto-review` remain explicitly
  unpriced; source-reported OpenCode/Pi cost remains separate.

### 2026-08-12 — Step 6: Aggregation and coordination

- Added local-calendar 1/7/30-day intervals, agent filtering, daily/model
  grouping, coverage counts, input cache-hit rate, and output share.
- Added one backend coordinator that imports each source independently,
  preserves prior indexed data on one-agent failure, then reprices all stored events.

### 2026-08-12 — Step 7: Fixture and runtime verification

- Added synthetic fixtures for all four importers, duplicate and append-only
  behavior, incomplete JSONL tails, partial records, store rollback/idempotence,
  price boundaries/cache classes/long context, aggregation, and DST boundaries.
- Ran the compiled Swift Testing bundle directly to avoid launching the app:
  59 tests in 2 suites passed, including 14 historical-backend tests.
- The documented unfiltered `xcodebuild build-for-testing ...` command
  succeeded. An earlier attempt hit a transient sandbox UI-test runner link
  denial; no source change was needed for the final successful run.
- Ran a read-only live-source import into `/private/tmp`:
  - cold: 5,473 events in 8,463 ms;
  - warm incremental: 0 new events in 130 ms;
  - importer issues: 0 for all four sources;
  - complete-event invariant violations: 0;
  - stored raw path leaks: 0.
- Live coverage after import: Claude Code 2,008 complete (2,003 priced), Codex
  2,465 complete + 935 partial (1,299 priced), OpenCode 6 complete (unpriced
  gateway models), and Pi 59 complete/priced.
- The live audit established that OpenCode `tokens.output` excludes reasoning
  while `tokens.total` includes it. The adapter and design doc were corrected so
  canonical `out` adds reasoning exactly once.

### 2026-08-12 — Step 8: Native SwiftUI dashboard

- Changed the range contract from 7/30/90 to the requested 1/7/30 local-calendar
  periods and added zero-valued daily points so charts do not connect across
  missing days as if activity were continuous.
- Preserved complete/priced event counts in daily and model groups; the UI marks
  partial pricing coverage instead of displaying unknown prices as free usage.
- Added a main-actor dashboard model that imports on first open, refreshes on
  demand, loads filter changes without rescanning histories, and preserves the
  last successful snapshot during source refresh failures.
- Added the aggregate Usage sidebar destination, toolbar range and Refresh
  controls, cost/token chart, four-agent legend, cost summary, normalized metric
  strip, model/day table, coverage footer, and empty/error/importing states.
- Added window-scoped range, chart, breakdown, and agent filters with
  `@SceneStorage`, plus a synthetic preview that cannot open the live index or
  scan agent histories.
- Existing Codex, Cursor, Claude Code quota pages and the menu-bar quota surface
  remain unchanged.

### 2026-08-12 — Step 9: Dashboard verification

- The exact non-launching `xcodebuild build-for-testing` command succeeded with
  the dashboard, Swift Charts, native Table, preview, and updated test bundle.
- Ran the compiled unit bundle directly: 60 tests in 2 suites passed, including
  15 historical analytics/dashboard tests and all 45 pre-existing quota tests.
- Attempted a runtime screenshot inspection of the built app through the
  computer-use path. macOS ScreenCaptureKit returned stream error `-3811`
  (`audio/video capture failure`), so no claim of interactive visual inspection
  is made. The launched debug app was then closed.
- `git diff --check` passes. A focused source scan found no credentials or real
  user paths in the dashboard implementation or synthetic fixtures.

### 2026-08-12 — Step 10: Chart fill and zero-agent correction

- Grouped each `AreaMark` explicitly by agent. The earlier ungrouped fill marks
  interleaved agent points, producing narrow cross-series wedges instead of one
  continuous fill under each curve.
- Replaced Catmull–Rom with monotone interpolation for both fills and lines so
  nonnegative usage samples cannot visually overshoot below zero.
- Made agent visibility metric-aware: Cost mode omits zero-cost series and
  Tokens mode omits zero-token series. Summary and model rows omit agents/models
  with zero total tokens.
- Preserved the unknown-versus-zero contract: token-bearing agents with no
  verified price display as `Unpriced` rather than `$0.00` and remain available
  in Tokens mode.

### 2026-08-12 — Step 11: Interactive curve hover

- Added a continuous pointer overlay to the daily chart. Hovering within a
  14-point radius of the nearest enabled series now displays a selected point,
  dashed horizontal and vertical guides, and an agent/date/value annotation.
- Kept hit-testing in plot coordinates and limited its input to enabled,
  metric-nonzero agents, so hidden or zero-usage series cannot capture hover.
- Added a focused screen-space segment projection helper with coverage for
  nearest-series selection, out-of-range rejection, and the single-point 1-day
  chart.
- The non-launching build succeeded and the directly executed test bundle
  passed 62 tests in 2 suites.

### 2026-08-12 — Step 12: Responsive metric-card layout

- Replaced the adaptive minimum-width grid with explicit 8/4/2/1-column
  `ViewThatFits` candidates.
- Each candidate uses equal flexible card widths with a 155-point minimum. The
  eight metrics therefore fill every selected layout without empty trailing
  cells or an incomplete final row.

### 2026-08-12 — Step 13: Rolling 24-hour chart and detailed breakdown

- Changed the former calendar-day `1d` range to an explicitly labeled rolling
  `24h` interval ending at query time; `7d` and `30d` retain local-calendar-day
  semantics.
- Separated range-aware chart points from calendar-day breakdown points. The
  24-hour chart uses local-hour buckets, including partial boundary hours,
  while Day mode remains grouped by date.
- Expanded both Model and Day rows with `in`, `cache-write`, `cache-read`,
  `out`, total, cost, cost share, input cache-hit rate, and output share.
- Preserved reasoning as an `out` subset exposed through the output-cell help,
  and preserved explicit partial/unpriced cost presentation.
- The non-launching build succeeded and the directly executed test bundle
  passed 63 tests, including rolling-boundary/hour-bucket and detailed-row
  reconciliation coverage.
