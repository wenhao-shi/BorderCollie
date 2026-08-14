# T-01 Trajectory implementation contract

## Authority and change control

This contract freezes the implementation boundary for T-01. Read it together with:

1. `/AGENTS.md`;
2. `/docs/trajectory-review-design.md`;
3. `/docs/usage-dashboard-design.md`;
4. `/docs/usage-dashboard-plan.md`.

The root project guide remains authoritative for repository-wide behavior. This contract narrows the approved Trajectory design into executable requirements. If implementation evidence makes a requirement impossible or internally inconsistent, stop at that boundary, record the evidence in `worklog.md`, and report the blocker. Do not silently change this contract, weaken an acceptance criterion, or ship a stand-in.

## Required outcome

Implement a native, metadata-only Trajectory destination for every session discoverable by BorderCollie's Claude Code, Codex, OpenCode, and Pi historical importers.

- Every supported session must have a truthful outer-turn trajectory from existing `UsageActiveTurn` records.
- Fine-grained model, tool, subtool, retry, first-output, and compaction activity is emitted only where Stage 0 proves stable source identity and lifecycle semantics.
- Unsupported detail is an explicit capability state, never a synthetic row or numeric zero.
- The feature is historical and refresh-driven. It is not a live agent event stream.
- `Open in Trajectory` navigation from Evaluations is not part of T-01.
- Commit, push, installation, and app launch are not authorized by this packet.

## Fixed architecture

### Existing truths that remain authoritative

1. `UsageActiveTurn` is the only persisted outer turn interval.
2. `UsageEvent` remains the only token/cost accounting record.
3. `UsageSourceImporter` remains the provider-specific parsing boundary.
4. `UsageImportBatch` carries usage, turns, trajectory metadata, and checkpoints produced from one consumed source prefix.
5. `UsageAnalyticsStore.apply(_:)` commits or rolls back one complete source batch.
6. `UsageAnalyticsBackend` remains the import coordinator.
7. The Trajectory screen gets a dedicated `TrajectoryBackend` and `@MainActor TrajectoryModel`.
8. A pure `TrajectoryProjection` derives hierarchy, lanes, ordering, time coordinates, range overlap, and display records.
9. Overview, ledger, and inspector exchange stable record IDs, never array indexes.

Do not add a second history scanner, raw-event database, event bus, repository protocol, backend protocol, renderer protocol, or factory unless a second real implementation appears and the user approves the design change.

### Required files

Add these production files under `BorderCollie/UsageDashboard/`:

- `TrajectoryModels.swift`
- `TrajectoryProjection.swift`
- `TrajectoryBackend.swift`
- `TrajectoryModel.swift`
- `TrajectoryView.swift`
- `TrajectoryTimeline.swift`
- `TrajectoryLedger.swift`

It is acceptable to combine the three view files only if the resulting file remains focused and materially easier to maintain. Do not combine domain, persistence, importer, projection, and view-model responsibilities.

Update at least:

- `UsageAnalyticsModels.swift`
- `UsageAnalyticsStore.swift`
- `UsageImporters.swift`
- `UsageAnalyticsBackend.swift`
- `ContentView.swift`
- `BorderCollie.xcodeproj/project.pbxproj` when file membership is not synchronized automatically
- relevant Swift Testing files
- `/docs/usage-dashboard-design.md`
- `/docs/usage-dashboard-plan.md`
- `/AGENTS.md`

## Public domain contracts

The declarations may be split across files, but their names, stored semantics, and externally used signatures are fixed unless a compile-time language constraint requires a mechanical adjustment.

```swift
enum TrajectoryActivityKind: String, Codable, CaseIterable, Sendable {
    case modelRequest = "model_request"
    case tool
    case subtool
    case retry
    case compaction
}

enum TrajectoryActivityStatus: String, Codable, CaseIterable, Sendable {
    case observed
    case open
    case succeeded
    case failed
    case interrupted
}

enum TrajectoryBoundaryQuality: String, Codable, CaseIterable, Sendable {
    case exact
    case inferred
}

enum TrajectoryOrderQuality: String, Codable, CaseIterable, Sendable {
    case sourceSequence = "source_sequence"
    case sourceRecord = "source_record"
    case timestamp
}

enum TrajectoryFailureCategory: String, Codable, CaseIterable, Sendable {
    case timeout
    case cancelled
    case toolError = "tool_error"
    case providerError = "provider_error"
    case unknown
}

enum TrajectoryCapabilityFamily: String, Codable, CaseIterable, Sendable {
    case turnTiming = "turn_timing"
    case modelTiming = "model_timing"
    case firstOutputTiming = "first_output_timing"
    case tools
    case toolNesting = "tool_nesting"
    case retries
    case compaction
}

enum TrajectoryCapabilityAvailability: String, Codable, CaseIterable, Sendable {
    case unavailable
    case partial
    case complete
}

enum TrajectoryPeriod: String, Codable, CaseIterable, Sendable {
    case last24Hours = "24h"
    case last7Days = "7d"
    case last30Days = "30d"
    case all
}

enum TrajectoryTimeMode: String, Codable, CaseIterable, Sendable {
    case order
    case activeTime = "active_time"
    case clockTime = "clock_time"
}

enum TrajectoryLane: String, Codable, CaseIterable, Sendable {
    case turn
    case model
    case tools
}
```

### Activity record

```swift
struct TrajectoryActivity: Equatable, Sendable, Identifiable {
    let id: String
    let agent: UsageAgent
    let sessionKey: String
    let turnID: String?
    let parentActivityID: String?

    let kind: TrajectoryActivityKind
    let status: TrajectoryActivityStatus
    let sourceOrder: Int64
    let orderQuality: TrajectoryOrderQuality

    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let firstOutputAtMilliseconds: Int64?
    let startQuality: TrajectoryBoundaryQuality
    let endQuality: TrajectoryBoundaryQuality?
    let firstOutputQuality: TrajectoryBoundaryQuality?

    let rawModelID: String?
    let toolName: String?
    let attempt: Int?
    let failureCategory: TrajectoryFailureCategory?
    let usageEventID: String?

    let sourceKey: String
    let sourceID: String
    let sourceSchemaVersion: String
    let importerVersion: Int

    static func normalized(
        agent: UsageAgent,
        sessionKey: String,
        turnID: String?,
        parentActivityID: String?,
        kind: TrajectoryActivityKind,
        status: TrajectoryActivityStatus,
        sourceOrder: Int64,
        orderQuality: TrajectoryOrderQuality,
        startedAtMilliseconds: Int64,
        endedAtMilliseconds: Int64?,
        firstOutputAtMilliseconds: Int64?,
        startQuality: TrajectoryBoundaryQuality,
        endQuality: TrajectoryBoundaryQuality?,
        firstOutputQuality: TrajectoryBoundaryQuality?,
        rawModelID: String?,
        toolName: String?,
        attempt: Int?,
        failureCategory: TrajectoryFailureCategory?,
        usageEventID: String?,
        sourceKey: String,
        sourceID: String,
        sourceSchemaVersion: String,
        importerVersion: Int
    ) throws -> TrajectoryActivity
}
```

`normalized` must enforce:

- non-empty `sessionKey`, `sourceKey`, `sourceID`, and `sourceSchemaVersion`;
- non-negative `sourceOrder` and positive `importerVersion`;
- `endedAtMilliseconds >= startedAtMilliseconds` when an end exists;
- `firstOutputAtMilliseconds >= startedAtMilliseconds` and no later than a known end;
- `status == .open` if and only if no terminal end exists, except point events;
- `status == .observed` requires equal start/end timestamps;
- terminal status requires an end and `endQuality`;
- `firstOutputQuality` exists if and only if first output exists;
- no self-parent relationship;
- model IDs only on model-request records;
- sanitized tool names only on tool/subtool records;
- positive retry attempt when present;
- deterministic `id == "\(agent.rawValue):\(sourceID)"`.

If source semantics require a point retry or compaction event, normalize it with equal start/end timestamps and `.observed`.

### Capability record

```swift
struct TrajectoryCapability: Equatable, Sendable, Identifiable {
    var id: String { "\(agent.rawValue):\(sessionKey):\(family.rawValue)" }

    let agent: UsageAgent
    let sessionKey: String
    let sourceKey: String
    let family: TrajectoryCapabilityFamily
    let availability: TrajectoryCapabilityAvailability
    let timingQuality: TrajectoryBoundaryQuality?
    let sourceSchemaVersion: String
    let importerVersion: Int

    static func normalized(
        agent: UsageAgent,
        sessionKey: String,
        sourceKey: String,
        family: TrajectoryCapabilityFamily,
        availability: TrajectoryCapabilityAvailability,
        timingQuality: TrajectoryBoundaryQuality?,
        sourceSchemaVersion: String,
        importerVersion: Int
    ) throws -> TrajectoryCapability
}
```

Availability and quality are independent:

- `.unavailable` has no timing quality;
- `.partial` may have exact or inferred known boundaries;
- `.complete` may still be inferred;
- observed event count must never determine capability availability.

`normalized` rejects empty identity/schema fields, non-positive importer versions, and a timing quality attached to `.unavailable`.

### Sanitizer

```swift
enum TrajectoryMetadataSanitizer {
    static func toolName(_ rawValue: String?) -> String?
}
```

The sanitizer removes Unicode control characters, trims surrounding whitespace, limits output to 128 Unicode scalar values, and returns `nil` for an empty result. No generic free-form text sanitizer is allowed; fields not explicitly allow-listed are discarded.

### Import batch additions

Extend the existing types without changing `UsageSourceImporter.importBatch(checkpoints:)`:

```swift
struct UsageImportBatch: Sendable {
    // existing fields remain
    var activities: [TrajectoryActivity]
    var trajectoryCapabilities: [TrajectoryCapability]
}

struct UsageAgentImportReport: Equatable, Sendable {
    // existing fields remain
    let importedActivities: Int
    let importedTrajectoryCapabilities: Int
}
```

### Session/query models

```swift
struct TrajectorySessionCursor: Equatable, Codable, Sendable {
    let startedAtMilliseconds: Int64
    let sessionKey: String
}

struct TrajectorySessionSummary: Equatable, Sendable, Identifiable {
    var id: String { sessionKey }

    let sessionKey: String
    let agent: UsageAgent
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64
    let turnCount: Int
    let activityCount: Int
    let usageEventCount: Int
    let modelIDs: [String]
}

struct TrajectorySessionPage: Equatable, Sendable {
    let sessions: [TrajectorySessionSummary]
    let nextCursor: TrajectorySessionCursor?
}

struct TrajectorySessionReport: Equatable, Sendable {
    let summary: TrajectorySessionSummary
    let turns: [UsageActiveTurn]
    let activities: [TrajectoryActivity]
    let capabilities: [TrajectoryCapability]
    let linkedUsageEvents: [UsageEvent]
}
```

Session list pagination is keyset pagination ordered by descending `(startedAtMilliseconds, sessionKey)`. The default limit is 200. Offset pagination is not permitted because new imported sessions would shift later pages.

Session summaries are derived from the union of usage events, active turns, and activities. Capability rows enrich a discovered session but cannot create one because they contain no timestamps. For an open activity, use its start as the provisional session end.

### Backend signatures

```swift
actor TrajectoryBackend {
    init(store: UsageAnalyticsStore)

    func refresh() async throws -> UsageImportReport

    func sessions(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        before cursor: TrajectorySessionCursor?,
        limit: Int,
        endingAt date: Date,
        calendar: Calendar
    ) async throws -> TrajectorySessionPage

    func report(sessionKey: String) async throws -> TrajectorySessionReport?
}
```

Production call sites may provide convenience overloads/default arguments, but the fully specified methods above must remain testable. `limit` must reject values outside `1...200` rather than silently allocating an unbounded result.

`TrajectoryBackend.refresh()` delegates to `UsageAnalyticsBackend.refresh()`. It does not duplicate import orchestration.

### Projection signatures

```swift
struct TrajectoryProjectedRecord: Equatable, Sendable, Identifiable {
    let id: String
    let parentID: String?
    let turnID: String?
    let depth: Int
    let lane: TrajectoryLane
    let canonicalOrder: Int
    let axisStart: Double
    let axisEnd: Double?
    let isPoint: Bool
    let isUnscoped: Bool
}

struct TrajectoryProjectionIssue: Equatable, Sendable, Identifiable {
    let id: String
    let recordID: String?
    let kind: Kind

    enum Kind: String, Codable, Sendable {
        case missingParent = "missing_parent"
        case parentCycle = "parent_cycle"
        case missingTurn = "missing_turn"
        case outsideActiveTime = "outside_active_time"
    }
}

struct TrajectoryProjectionResult: Equatable, Sendable {
    let records: [TrajectoryProjectedRecord]
    let issues: [TrajectoryProjectionIssue]
    let axisLowerBound: Double
    let axisUpperBound: Double
}

enum TrajectoryProjection {
    static func make(
        report: TrajectorySessionReport,
        mode: TrajectoryTimeMode,
        collapsedRecordIDs: Set<String>
    ) -> TrajectoryProjectionResult

    static func recordIDs(
        overlapping range: ClosedRange<Double>,
        in projection: TrajectoryProjectionResult
    ) -> Set<String>
}
```

The projection is pure: no disk, SQLite, `Date.now`, network, global state, SwiftUI, or provider parsing.

## Persistence contract

Set `UsageAnalyticsStore.schemaVersion = 4`.

### `trajectory_activity`

The table must contain exactly normalized metadata columns equivalent to:

```sql
CREATE TABLE trajectory_activity (
    id TEXT PRIMARY KEY,
    agent TEXT NOT NULL,
    session_key TEXT NOT NULL CHECK(length(session_key) > 0),
    turn_id TEXT,
    parent_activity_id TEXT,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    source_order INTEGER NOT NULL CHECK(source_order >= 0),
    order_quality TEXT NOT NULL,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER CHECK(ended_at_ms IS NULL OR ended_at_ms >= started_at_ms),
    first_output_at_ms INTEGER,
    start_quality TEXT NOT NULL,
    end_quality TEXT,
    first_output_quality TEXT,
    raw_model_id TEXT,
    tool_name TEXT,
    attempt INTEGER CHECK(attempt IS NULL OR attempt > 0),
    failure_category TEXT,
    usage_event_id TEXT,
    source_key TEXT NOT NULL CHECK(length(source_key) > 0),
    source_id TEXT NOT NULL,
    source_schema_version TEXT NOT NULL,
    importer_version INTEGER NOT NULL CHECK(importer_version > 0),
    UNIQUE(agent, source_id)
);
```

Do not add foreign keys for `turn_id`, `parent_activity_id`, or `usage_event_id`; partial histories must remain representable. Normalization/projection validates relationships.

Required indexes:

```sql
CREATE INDEX trajectory_activity_session_order
ON trajectory_activity(session_key, source_order, started_at_ms);

CREATE INDEX trajectory_activity_session_time
ON trajectory_activity(session_key, started_at_ms, ended_at_ms);

CREATE INDEX trajectory_activity_source
ON trajectory_activity(agent, source_key);

CREATE INDEX trajectory_activity_parent
ON trajectory_activity(parent_activity_id);
```

### `trajectory_capability`

```sql
CREATE TABLE trajectory_capability (
    agent TEXT NOT NULL,
    session_key TEXT NOT NULL CHECK(length(session_key) > 0),
    source_key TEXT NOT NULL CHECK(length(source_key) > 0),
    family TEXT NOT NULL,
    availability TEXT NOT NULL,
    timing_quality TEXT,
    source_schema_version TEXT NOT NULL,
    importer_version INTEGER NOT NULL CHECK(importer_version > 0),
    PRIMARY KEY(agent, session_key, family)
);

CREATE INDEX trajectory_capability_source
ON trajectory_capability(agent, source_key);
```

Migration 3 to 4 creates these empty tables/indexes and preserves every existing table and row. Fresh schema creation and incremental migration must produce equivalent schema.

### Atomicity

Within `UsageAnalyticsStore.apply(_:)`:

1. Validate all usage events, turns, activities, capabilities, and checkpoints belong to `batch.agent`.
2. Delete all four imported record families plus checkpoint for reset/removed source keys.
3. Upsert usage events, turns, activities, and capabilities.
4. Upsert checkpoints last.
5. Roll back the entire source batch on any failure.

The importer may skip an isolated invalid trajectory fragment only when doing so cannot corrupt later correlation. Structural ambiguity fails the source batch and preserves its prior checkpoint/data.

## Source evidence contract

Stage 0 is a blocking implementation phase. For every source/schema variant, record in `/docs/trajectory-review-design.md`:

- stable session, turn, request, call, parent, and usage-link fields;
- start, first-output, terminal, failure, retry, and compaction semantics;
- ordering source and fallback;
- availability and exact/inferred quality per capability family;
- fields read, fields retained, and fields discarded;
- evidence location: upstream source/docs or local installed schema mechanism.

Audit private local histories only when public/installed source code cannot answer the question. When local records are necessary:

- inspect keys, types, and redacted structural summaries;
- never print or copy content values, paths, prompts, responses, commands, arguments, results, or stable local identifiers;
- create synthetic fixtures manually from the proven structure;
- never add a real local record to the repository.

No fine-grained mapping is accepted without a synthetic fixture and a code comment naming its audited source fields. If a source cannot prove a lifecycle, emit `.unavailable` or `.partial` capability and no invented activity.

## Privacy contract

Allowed persisted/searchable data:

- agent and hashed session/source/lifecycle IDs;
- kind, hierarchy, source order, status, timestamps, and boundary quality;
- model identifiers;
- sanitized tool names;
- retry attempt and allow-listed failure category;
- source schema/importer versions;
- capability availability/quality;
- logical links to existing normalized usage events.

Prohibited everywhere, including database, checkpoints, logs, search, fixtures, previews, accessibility text, errors, worklog, and report:

- prompts, system messages, responses, or reasoning text;
- transcript titles derived from content;
- tool arguments, results, schemas, commands, patches, or terminal output;
- working directories, project/repository names, raw source paths, or URLs;
- request/response headers/bodies, credentials, cookies, or tokens;
- raw JSONL records, database message blobs, or free-form source errors.

Parse by allow-list. Do not serialize and then redact a source record.

## Timing and projection contract

- Order is the default mode and uses equal record slots in canonical source order.
- Active time uses recorded duration while removing gaps outside the union of `UsageActiveTurn` intervals.
- Clock time preserves wall-clock gaps.
- The visible axis always names its mode.
- Open records render start markers and never extend to the current time.
- Point events have equal start/end.
- Missing first-output evidence produces no TTFT.
- Use the label `TTFT` only if Stage 0 proves first-token semantics. Otherwise use `First output` and document its source meaning.
- Active-time activities outside all turns stay out of the compressed plot, remain in the ledger, and carry an unscoped/outside-active-time issue.
- Range overlap is inclusive: `recordStart <= range.upperBound && recordEnd >= range.lowerBound`; a point uses the same timestamp for both bounds.
- Negative/reversed intervals are rejected, never clamped.

## UI contract

- Add `Trajectory` as a fourth root sidebar destination.
- Use `HSplitView` inside the root detail: inset paged session list left, selected-session detail right.
- Toolbar: period, agent filter, timeline mode, and Refresh.
- Periods: 24h, 7d, 30d, All. Store period/agent/mode in `@SceneStorage`.
- Session list labels use only agent, time, model set, duration, counts, and abbreviated hashed session key.
- Detail: metadata header, capability summary, fixed three-lane overview, hierarchical ledger, and metadata inspector.
- Lanes: Turn, Model, Tools.
- Ledger columns: kind, allow-listed model/tool label, status, start, duration, evidence quality.
- Inspector: identity, hierarchy, timestamps, derived duration/first-output timing, capability explanation, and linked normalized tokens/cost.
- No payload/result/prompt/reasoning/schema/command view.
- Filtering covers only kind, status, model ID, sanitized tool name, and failure category.
- Overview and ledger selection use the same stable record ID.
- Turn/tool folding must not change identity.
- Escape and an explicit close control clear inspector selection.
- A `Table` owns the ledger scroll. Do not nest it inside another scroll view.
- The root window owns minimum size.
- Use `UsageDesign`, `GroupBox`, continuous corners, sentence case, and non-colour status channels.
- Use `ContentUnavailableView` for empty/error states with Refresh when recoverable.
- Use `PreviewProvider` and fully synthetic injected reports. Previews perform no disk, database, credential, process, or network access.

## Performance contract

Before adding custom virtualization, measure synthetic sessions containing 100, 1,000, and 10,000 activities in a release build.

Acceptance target: projection and timeline-mode recomputation for 10,000 activities completes in less than 100 ms on the development Mac, and scrolling has no repeated multi-frame stalls. This is a target, not a currently measured fact.

If the target fails, profile first. Add SQL detail paging, projection caching, or custom virtualization only when measurements identify the bottleneck. Record commands, hardware/OS, dataset shape, and results in `worklog.md` and `report.md`.

## Test and verification contract

Required automated coverage:

- activity/capability normalization invariants and tool-name sanitizer;
- schema-3-to-4 migration and fresh-schema equivalence;
- atomic rollback, checkpoint preservation, reset/removal isolation, and idempotent upsert;
- one synthetic suite per provider covering every supported and unavailable capability;
- lifecycle start in one batch and terminal update in a later batch;
- hierarchy, orphan, cycle, ordering, open/point records, and unscoped activity;
- Order, Active time, Clock time, idle compression, and inclusive range overlap;
- session keyset pagination and stable ordering under a newly imported leading session;
- backend usage-link joins only by explicit ID;
- view-model stale-result rejection, paging, refresh failure preservation, selection, and preview isolation;
- privacy checks proving prohibited source fields never reach stored models or issue strings.

Use Swift Testing for test code. Run relevant focused tests during development, then the repository's non-launching compile verification:

```sh
xcodebuild build-for-testing \
  -project BorderCollie.xcodeproj \
  -scheme BorderCollie \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/BorderCollieDerivedDataBuild \
  CODE_SIGNING_ALLOWED=NO
```

Do not run app-hosted tests or launch the app unless separately authorized and necessary for an explicit runtime gate. Report exactly which tests ran and distinguish compile, unit, preview/static, and measured runtime evidence.

## Completion contract

Before declaring T-01 complete:

1. Meet all acceptance criteria in `/docs/trajectory-review-design.md`.
2. Update repository architecture/privacy documentation to match implemented—not planned—behavior.
3. Update `worklog.md` throughout execution with evidence and decisions.
4. Fill `report.md` with files changed, source capability matrix, migrations, tests, performance measurements, privacy verification, remaining unavailable capabilities, and exact limitations.
5. Run `git diff --check` and inspect the full working-tree diff/status.
6. Preserve unrelated user changes and leave commit/push/install undone unless separately authorized.
