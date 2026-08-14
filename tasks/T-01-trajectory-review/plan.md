# T-01 Trajectory implementation plan

## Execution rule

Follow the stages in order. Stage 0 is a blocking evidence gate; persistence and importer code must not be designed around guessed source fields. Keep the app buildable at the end of every implementation stage. Record commands, evidence, decisions, failures, and validation results in `worklog.md` as they occur.

The fixed interface and privacy requirements are in `contract.md`. If this plan and the contract appear to conflict, the contract wins and the executor must record the conflict rather than choosing silently.

## Stage 0: establish the evidence matrix

### Read and inventory

- [ ] Read `/AGENTS.md` completely.
- [ ] Read `/docs/trajectory-review-design.md` completely.
- [ ] Read `/docs/usage-dashboard-design.md` before changing import/store semantics.
- [ ] Read `contract.md`, this plan, `prompt.md`, and the current `worklog.md`.
- [ ] Inspect `git status`, staged/unstaged diffs, and untracked files; identify task-owned paths without touching unrelated work.
- [ ] Read all four existing importers, import support, models, store migration/apply path, analytics backend, evaluation backend/model/view, root navigation, design tokens, and relevant tests.

### Audit sources

- [ ] Identify the durable installed/schema variants for Codex, Claude Code, OpenCode, and Pi.
- [ ] Prefer upstream or installed source code and documented schemas over private history inspection.
- [ ] If private local records are required, inspect only redacted structure and never expose prohibited values in terminal output, worklog, fixtures, or reports.
- [ ] For each provider, prove or reject session identity, turn identity, model request, first output, tool call/result, parent nesting, retry, compaction, ordering, and usage-event linkage.
- [ ] Classify each capability family by availability and timing quality.
- [ ] Add the evidence matrix and exact source mechanisms to `/docs/trajectory-review-design.md`.
- [ ] Build minimal synthetic fixtures from the audited structure.

### Gate 0

- [ ] Every fine-grained mapping has a stable identity/boundary mechanism, evidence pointer, and synthetic fixture.
- [ ] Unknown mappings are explicitly unavailable/partial.
- [ ] The user-facing term is `TTFT` only for actual first-token evidence; otherwise it is `First output`.
- [ ] No real content or stable local identifier exists in a fixture or document.

If this gate cannot be met for a detail family, do not block the whole feature: preserve coarse outer turns and mark that family unavailable. If no provider exposes any fine-grained evidence, continue with the complete turn-only Trajectory destination because that is the evidence-backed product outcome defined by the design—not a fabricated detailed substitute.

## Stage 1: add normalized domain contracts

### Implement

- [ ] Add `TrajectoryModels.swift` with the contract enums and records.
- [ ] Implement `TrajectoryActivity.normalized(...)` and explicit normalization errors.
- [ ] Implement `TrajectoryMetadataSanitizer.toolName(_:)` by allow-list.
- [ ] Add session cursor, summary, page, and report types.
- [ ] Extend `UsageImportBatch` and `UsageAgentImportReport` with trajectory counts.

### Test

- [ ] Valid open, point, succeeded, failed, and interrupted records.
- [ ] Reversed/negative intervals and invalid first-output milestones.
- [ ] Status/end-quality consistency.
- [ ] Self-parent, kind-specific model/tool fields, retry attempt, and stable ID.
- [ ] Tool-name control removal, trimming, scalar limit, and empty output.

### Gate 1

- [ ] Focused model tests pass.
- [ ] Existing usage/evaluation model tests retain their semantics.
- [ ] No source payload type leaks into domain declarations.

## Stage 2: migrate and extend SQLite atomically

### Implement

- [ ] Raise schema version from 3 to 4.
- [ ] Add fresh-schema DDL for `trajectory_activity`, `trajectory_capability`, and required indexes.
- [ ] Add version-3 migration without dropping or rewriting existing tables.
- [ ] Add bind/decode/upsert methods for activities and capabilities.
- [ ] Extend batch-agent validation.
- [ ] Extend reset/removal deletion by `(agent, source_key)`.
- [ ] Upsert checkpoints last inside the existing transaction.
- [ ] Add store reads needed by session discovery, detail reports, and linked usage IDs.

### Test

- [ ] Fresh schema and migrated schema expose equivalent version-4 trajectory tables/indexes.
- [ ] Migration preserves usage events, turns, evaluations, selected sessions, pricing, aliases, and checkpoints.
- [ ] One invalid trajectory write rolls back usage, turns, activities, capabilities, and checkpoint together.
- [ ] Reset/removal deletes only one source's records.
- [ ] Repeated apply is idempotent.
- [ ] Stored rows round-trip every enum/optional field or fail with a precise invalid-stored-value error.
- [ ] SQL schema contains no prohibited payload/free-text column.

### Gate 2

- [ ] All store and migration tests pass.
- [ ] An existing schema-3 fixture remains readable after migration.
- [ ] Transaction tests prove the checkpoint never advances alone.

## Stage 3: normalize provider evidence in existing import passes

Implement providers in descending evidence strength found in Stage 0. Do not assume an order before the audit.

### Per-provider loop

- [ ] Increment that importer version when normalized output changes.
- [ ] Emit per-session capability declarations independent of observed activity count.
- [ ] Emit deterministic activities only for audited lifecycle records.
- [ ] Link `turnID`, parent activity, and usage event only through stable source IDs.
- [ ] Retain open activities and metadata-only pending correlation across incremental JSONL batches when required.
- [ ] Sanitize tool names before they enter the batch.
- [ ] Map only allow-listed failure categories.
- [ ] Keep valid usage/turn import behavior unchanged.

### Per-provider tests

- [ ] Clean import.
- [ ] No-op repeated import.
- [ ] Start in one batch, terminal in a later batch, one stable resulting ID.
- [ ] Multiple concurrent/nested calls if the source supports them.
- [ ] Missing terminal record remains open, not failed or extended to now.
- [ ] Malformed isolated fragment versus structural ambiguity behavior.
- [ ] Truncated/replaced source and importer-version rebuild.
- [ ] Same clean and rebuilt input produces identical IDs/order/capabilities.
- [ ] Unsupported kinds remain unavailable rather than zero.
- [ ] Privacy assertions cover stored values and issue text.

### Gate 3

- [ ] Claude Code, Codex, OpenCode, and Pi all still produce their current coarse `UsageActiveTurn` timeline.
- [ ] Every detailed mapping in code is present in the Stage 0 evidence matrix.
- [ ] Every mapping has synthetic coverage.
- [ ] Import remains one scan and one atomic batch per source.

## Stage 4: implement session queries and backend

### Implement

- [ ] Add keyset-paginated session discovery from the union of usage, turns, and activities; join capabilities after discovery.
- [ ] Support 24h, local-calendar 7d, local-calendar 30d, and All periods.
- [ ] Filter by selected agents without losing sessions that have only activities; capability rows enrich but do not create a time-addressable session.
- [ ] Add detail reads for turns, activities, capabilities, and explicitly linked usage events.
- [ ] Add `TrajectoryBackend` with the contract signatures.
- [ ] Delegate refresh to `UsageAnalyticsBackend.refresh()`.
- [ ] Reject limits outside `1...200`.

### Test

- [ ] Sessions derived from each record family and their unions.
- [ ] Newest-first deterministic ordering and abbreviated cursor ties.
- [ ] New leading sessions do not shift a previously issued next page.
- [ ] Period boundary and local-calendar behavior.
- [ ] Agent filters and All period.
- [ ] Detail report cannot return unlinked nearest-time usage events.
- [ ] One source refresh failure preserves other/previous sessions.

### Gate 4

- [ ] Every discoverable session is reachable through All-period paging.
- [ ] A session with an incomplete turn but a stored started activity remains discoverable; its start is the provisional session end.
- [ ] Backend tests and existing analytics/evaluation tests pass.

## Stage 5: build the pure projection

### Implement

- [ ] Build canonical records for turns plus fine-grained activities.
- [ ] Validate parents within the same session.
- [ ] Detect self-parent, missing parent, and cycles; a parent absent from the selected session is treated as missing rather than looked up by timestamp.
- [ ] Keep orphans/root records visible with projection issues.
- [ ] Flatten hierarchy deterministically with stable depth and canonical order.
- [ ] Map Turn, Model, and Tools lanes.
- [ ] Implement Order mode with equal record slots.
- [ ] Implement Active time from the union of outer turns, excluding unscoped activities from the compressed plot.
- [ ] Implement Clock time with wall-clock gaps.
- [ ] Implement inclusive range overlap and collapsed-record filtering.

### Test

- [ ] Equal timestamps and source-order ties.
- [ ] Point and open records.
- [ ] Deep tool nesting, missing parent, and cycles.
- [ ] Turn grouping only through `turnID`.
- [ ] Retry linkage only through parent ID.
- [ ] Active-time union/idle compression with overlapping turns.
- [ ] Unscoped activities remain in the ledger and produce an issue.
- [ ] Clock time preserves idle.
- [ ] Order mode does not encode duration.
- [ ] Inclusive range selection includes boundary points.
- [ ] Collapsing a parent preserves identities and selection validity.

### Gate 5

- [ ] Projection is a deterministic pure function.
- [ ] Timeline and ledger consume one result and one record-ID namespace.
- [ ] No view code recalculates hierarchy or source correlation.

## Stage 6: implement view model and destination

### View model

- [ ] Add `@MainActor TrajectoryModel` with injected live/preview backends or data.
- [ ] Store period, agent filter, and mode in window-scoped `@SceneStorage` at the view boundary.
- [ ] Load initial page, load earlier pages, refresh, select session, and load report.
- [ ] Reject stale async page/report results with revisions or task cancellation.
- [ ] Preserve last successful sessions/report on refresh failure.
- [ ] Keep overview/ledger/inspector selection as one stable record ID.

### SwiftUI

- [ ] Add `Trajectory` to root navigation.
- [ ] Build native `HSplitView`, inset session list, toolbar filters/mode/Refresh, and detail states.
- [ ] Build metadata header and capability summary.
- [ ] Build fixed Turn/Model/Tools overview with a visible mode label.
- [ ] Build hierarchical `Table` ledger without a containing scroll view.
- [ ] Build metadata-only inspector.
- [ ] Add folding, hover timing, inclusive range selection, search/filter, Escape, and close control.
- [ ] Use `UsageDesign`, `GroupBox`, continuous shapes, sentence case, native controls, and non-colour status channels.
- [ ] Add complete accessibility labels/values.
- [ ] Add `PreviewProvider` with synthetic data and no live services.

### Gate 6

- [ ] Coarse turn-only sessions are useful and visibly limited.
- [ ] Unsupported and observed-zero states have different copy.
- [ ] Open records have markers, not fabricated spans.
- [ ] `TTFT` appears only for proven first-token sources.
- [ ] No prohibited content appears in the UI, search, accessibility, or errors.
- [ ] No nested scrolling or detail-owned minimum window size.
- [ ] View-model tests pass and previews are static/synthetic.

## Stage 7: measure scale before optimizing

### Measure

- [ ] Generate deterministic synthetic reports at 100, 1,000, and 10,000 activities.
- [ ] Measure projection creation and each mode switch in a release build.
- [ ] Inspect scrolling/selection behavior at 10,000 activities.
- [ ] Record development Mac hardware, macOS version, build configuration, commands, dataset shape, repeated samples, and result distribution.

### Decide from evidence

- [ ] If 10,000-record projection/mode recomputation is below 100 ms and UI interaction avoids repeated multi-frame stalls, keep the simple design.
- [ ] If not, profile and identify whether SQL loading, projection, SwiftUI diffing, layout, or drawing dominates.
- [ ] Add only the measured remedy: detail paging, cached projection, or custom virtualization.
- [ ] Repeat the same measurement and record before/after evidence.

### Gate 7

- [ ] The chosen long-session mechanism has measured support.
- [ ] Unmeasured or failed targets remain explicit in the final report.

## Stage 8: privacy, regression, and documentation closure

### Audit

- [ ] Inspect schema, models, checkpoint state, logging, errors, fixtures, previews, search index, and accessibility text against the prohibited-field list.
- [ ] Search for accidental raw JSON/message storage and free-form payload/error fields.
- [ ] Confirm sources are opened read-only and never modified.
- [ ] Confirm historical refresh is not connected to live quota timers.
- [ ] Confirm Cursor remains excluded from historical trajectory.

### Documentation

- [ ] Update `/docs/usage-dashboard-design.md` with implemented schema, privacy contract, UI semantics, and source capability matrix.
- [ ] Update `/docs/usage-dashboard-plan.md` with completed stages and actual validation.
- [ ] Update `/AGENTS.md` repository layout, standards, pitfalls, and verification guidance.
- [ ] Ensure `/docs/trajectory-review-design.md` distinguishes implemented behavior from deferred/unavailable behavior.

### Final verification

- [ ] Run all focused unit tests.
- [ ] Run the non-launching `xcodebuild build-for-testing` command in `contract.md`.
- [ ] Run `git diff --check`.
- [ ] Inspect `git status`, staged/unstaged diff, and untracked files.
- [ ] Verify no unrelated user changes were modified or staged.
- [ ] Fill `report.md` completely and make the final `worklog.md` entry.

### Completion gate

- [ ] Every contract acceptance requirement is implemented or explicitly blocked by evidence.
- [ ] No required work is silently deferred.
- [ ] No commit, push, install, or app launch occurred without separate authorization.
