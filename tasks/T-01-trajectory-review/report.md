# T-01 Trajectory executor report

Status: Implemented with the evidence-backed coarse boundary. The destination,
metadata schema, importer integration, projection, UI, and focused test code are
present. All four providers expose outer-turn timing; no finer activity is
claimed where Stage 0 did not prove identity and lifecycle semantics.

## Design and contract compliance

| Requirement | Result | Evidence |
| --- | --- | --- |
| Standalone Trajectory destination | Implemented | `ContentView.swift`; `TrajectoryView.swift` |
| Every indexed provider has coarse turns | Implemented | Existing importer timing paths and capability helper in `UsageImporters.swift` |
| Fine detail only from proven source evidence | Implemented | Stage 0 matrix in `trajectory-review-design.md`; no fine rows emitted |
| Capability availability separate from timing quality | Implemented | `TrajectoryModels.swift`; importer capability rows |
| Existing turn/accounting records remain canonical | Implemented | `UsageActiveTurn` and `UsageEvent` remain the source of report data |
| Single importer scan and atomic batch | Implemented | `UsageImporters.swift`; `UsageAnalyticsStore.apply` |
| Order, Active time, and Clock time modes | Implemented | Pure `TrajectoryProjection` |
| Shared stable selection identity | Implemented | Projected record IDs feed timeline, ledger, and inspector |
| Metadata-only privacy boundary | Implemented | Allow-listed schema, sanitizer, generic issue messages, no payload columns |
| Long-session measurement gate | Measured for projection | Release synthetic benchmark is below 100 ms at 10,000 activities; scrolling was not runtime-checked |

## Source capability matrix

Availability and timing quality are separate. The exact source mechanisms are
the existing importer fields documented in `trajectory-review-design.md` and
the synthetic provider fixtures in `UsageDashboardTests.swift`.

| Source/schema | Turn timing | Model timing | First output | Tools | Nesting | Retries | Compaction | Usage link |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex rollout | Complete, exact: task start/completion markers | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Claude transcript | Complete, inferred: human/terminal assistant boundary | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| OpenCode message | Complete, exact: assistant creation/completion timestamps | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Pi session | Complete, inferred: user/terminal assistant boundary | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |

No `TTFT` label is used. First-output timing is not shown because none of the
audited source fields proves first-token or first-output lifecycle semantics.

## Architecture delivered

- `TrajectoryModels.swift` defines normalized activity/capability contracts,
  invariant checks, metadata sanitization, session query models, and periods.
- `UsageAnalyticsStore.swift` migrates schema 3 to 4, creates the required
  indexes, atomically upserts/deletes trajectory rows, and derives paged
  sessions and reports from usage events, turns, and activities.
- `UsageImporters.swift` keeps all provider parsing in the existing pass,
  increments importer versions, and emits one capability matrix per discovered
  session. The implementation intentionally emits no speculative fine rows.
- `TrajectoryBackend.swift` delegates refresh to `UsageAnalyticsBackend` and
  exposes bounded keyset/session/report reads.
- `TrajectoryProjection.swift` is pure and handles hierarchy validation, cycle
  breaking, stable flattening, lanes, open/point records, inclusive overlap,
  and all three time modes.
- `TrajectoryModel.swift` owns main-actor loading, refresh, paging, selection,
  stale-result revisions, preview injection, and stale-data errors.
- The SwiftUI destination uses an inset `HSplitView`, toolbar filters, fixed
  Turn/Model/Tools overview, inclusive drag-range selection, hierarchical
  `Table`, metadata inspector, stable selection, close/Escape handling, and
  synthetic preview injection.

## Files changed

Production: `TrajectoryModels.swift`, `TrajectoryProjection.swift`,
`TrajectoryBackend.swift`, `TrajectoryModel.swift`, `TrajectoryView.swift`,
`TrajectoryTimeline.swift`, `TrajectoryLedger.swift`, plus updates to
`UsageAnalyticsModels.swift`, `UsageAnalyticsStore.swift`,
`UsageImporters.swift`, `UsageAnalyticsBackend.swift`, and `ContentView.swift`.

Tests: `TrajectoryTests.swift` plus provider capability assertions in
`UsageDashboardTests.swift`.

Documentation: `AGENTS.md`, `trajectory-review-design.md`,
`usage-dashboard-design.md`, `usage-dashboard-plan.md`, and this task report.
The Xcode project file required no manual edit because its synchronized source
group discovers the new Swift files.

## Migration and data integrity

- Fresh schema version: 4.
- The migration path creates only the two trajectory tables and their indexes
  when opening schema 3; it does not rewrite existing usage/evaluation tables.
- Focused tests cover schema-3 preservation, idempotent upsert, invalid-batch
  rollback, checkpoint preservation, and explicit usage-link joins. They were
  executed through the focused macOS unit-test host and passed.
- Reset/removal handling deletes events, turns, activities, capabilities, and
  checkpoints for the affected `(agent, sourceKey)` only.
- No local user database was opened or migrated during validation.

## Privacy review

The review inspected the normalized model columns, trajectory DDL, importer
batch contents, checkpoint fields, issue construction, search values,
accessibility labels, and preview construction. Stored/searchable trajectory
data is limited to hashed or source-derived identities, allow-listed kind and
status, ordering, timestamps, quality, model IDs, sanitized tool names, retry
metadata, capability state, and explicit usage-event IDs. No payload/result,
prompt, response, reasoning, command, header, credential, or raw record field
is represented by the trajectory schema or UI. Source databases/files remain
read-only inputs.

Residual risk: provider schema changes can invalidate the current coarse
boundary assumptions; importer-version changes trigger source rebuilds, but
runtime validation against future provider versions remains outside this task.

## Verification

| Check | Scope | Result | Boundary |
| --- | --- | --- | --- |
| 8 focused Trajectory Swift Testing cases | Normalization, projection, store, real schema migration/equivalence, keyset stability, and model selection | Passed | Executed with `test-without-building` |
| Complete 80-case unit-test target | Existing tracker, importer, store, aggregation, and Trajectory suites | Passed | UI-test target was not run |
| Xcode `build-for-testing` | App, unit-test, and UI-test target compilation | Passed | Does not prove launched UI behavior |
| Release projection benchmark | 100/1,000/10,000 synthetic activities, all modes | Passed target | Does not measure scrolling or selection stalls |
| `git diff --check` | Patch whitespace | Passed | No runtime implication |

## Performance measurements

Development machine: MacBook Pro Mac15,6, Apple M3 Pro, 11 cores, 36 GB,
macOS 26.6.1. A release Swift executable was compiled from the normalized
models and pure projection, then measured after one warmup with five samples per
mode. Each synthetic report contained one 60-second outer turn and the listed
number of deterministic sibling model/tool activities.

| Activities | Order projection (ms) | Active-time projection (ms) | Clock-time projection (ms) |
| ---: | ---: | ---: | ---: |
| 100 | 0.326 | 0.303 | 0.274 |
| 1,000 | 2.682 | 2.054 | 1.722 |
| 10,000 | 13.613 | 12.725 | 12.683 |

The under-100-ms projection/mode target passed for this shape. No custom
virtualization or projection cache was added. Scrolling and selection require
runtime UI validation before claiming long-session interaction readiness.

## Deviations and decisions

- Fine-grained provider activity was not invented. This is the required
  contract outcome when Stage 0 cannot prove stable lifecycle evidence.
- The initial task pass kept the tests compile-only because the packet did not
  authorize launching the host. The follow-up fix request explicitly closed
  that review gate; the focused Trajectory suite and complete unit-test target
  were then executed with `test-without-building`. No interactive app or UI-test
  run was performed.
- No project-file edit was needed because source membership is synchronized.

## Remaining limitations and blockers

- Model-request, first-output, tool, subtool, nesting, retry, and compaction
  capabilities are unavailable for all four current provider schemas.
- No explicit usage-event links are emitted until a source proves them; coarse
  turns therefore show no token/cost detail in the trajectory inspector.
- Preview rendering, VoiceOver inspection, scrolling, and pointer-driven range
  interaction remain unmeasured. View-model selection behavior is now covered
  by an executed unit test.
- Provider schema-version changes require a new Stage 0 audit before adding any
  fine activity mapping.

## Repository and delivery state

- Branch: `t-01-trajectory-prep`
- Working tree: task changes present; no unrelated baseline changes were found.
- Commit: not authorized; none created.
- Push: not authorized; none performed.
- Installation: none performed.
- App launch/runtime UI validation: not performed.

## Worklog

Execution evidence and chronological decisions: [`worklog.md`](worklog.md)
