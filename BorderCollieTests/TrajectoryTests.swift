import Foundation
import SQLite3
import Testing
@testable import BorderCollie

struct TrajectoryTests {
    @Test func activityNormalizationSanitizesAndKeepsStableIdentity() throws {
        let activity = try makeActivity(
            kind: .tool,
            sourceID: "call-1",
            rawModelID: nil,
            toolName: "  shell\u{0000}  "
        )

        #expect(activity.id == "codex:call-1")
        #expect(activity.toolName == "shell")
        #expect(TrajectoryMetadataSanitizer.toolName("\u{0000} \n") == nil)
        let point = try makeActivity(
            kind: .retry,
            status: .observed,
            sourceID: "retry-1",
            end: 1_000,
            rawModelID: nil,
            attempt: 1
        )
        #expect(point.startedAtMilliseconds == point.endedAtMilliseconds)
        #expect(throws: TrajectoryNormalizationError.self) {
            try makeActivity(parentActivityID: "codex:call-2", kind: .tool, sourceID: "call-2")
        }
        #expect(throws: TrajectoryNormalizationError.self) {
            try makeActivity(kind: .modelRequest, sourceID: "call-3", toolName: "not-allowed")
        }
        #expect(throws: TrajectoryNormalizationError.self) {
            try makeActivity(kind: .retry, sourceID: "call-4", attempt: 0)
        }
    }

    @Test func capabilityAvailabilityDoesNotDependOnObservedActivity() throws {
        let unavailable = try TrajectoryCapability.normalized(
            agent: .claudeCode,
            sessionKey: "session-1",
            sourceKey: "source-1",
            family: .tools,
            availability: .unavailable,
            timingQuality: nil,
            sourceSchemaVersion: "fixture-v1",
            importerVersion: 3
        )
        let partial = try TrajectoryCapability.normalized(
            agent: .claudeCode,
            sessionKey: "session-1",
            sourceKey: "source-1",
            family: .turnTiming,
            availability: .partial,
            timingQuality: .inferred,
            sourceSchemaVersion: "fixture-v1",
            importerVersion: 3
        )

        #expect(unavailable.id == "claude_code:session-1:tools")
        #expect(unavailable.timingQuality == nil)
        #expect(partial.availability == .partial)
        #expect(partial.timingQuality == .inferred)
        #expect(throws: TrajectoryNormalizationError.self) {
            try TrajectoryCapability.normalized(
                agent: .claudeCode,
                sessionKey: "session-1",
                sourceKey: "source-1",
                family: .tools,
                availability: .unavailable,
                timingQuality: .exact,
                sourceSchemaVersion: "fixture-v1",
                importerVersion: 3
            )
        }
    }

    @Test func projectionPreservesHierarchyAndSupportsAllTimeModes() throws {
        let turn = try makeTurn()
        let request = try makeActivity(
            turnID: turn.id,
            kind: .modelRequest,
            sourceID: "request-1",
            start: 1_000,
            end: 4_000,
            rawModelID: "model-a"
        )
        let tool = try makeActivity(
            turnID: turn.id,
            parentActivityID: request.id,
            kind: .tool,
            status: .open,
            sourceID: "tool-1",
            start: 2_000,
            end: nil,
            rawModelID: nil,
            toolName: "tool-a"
        )
        let report = makeReport(turns: [turn], activities: [request, tool])

        let order = TrajectoryProjection.make(report: report, mode: .order, collapsedRecordIDs: [])
        let active = TrajectoryProjection.make(report: report, mode: .activeTime, collapsedRecordIDs: [])
        let clock = TrajectoryProjection.make(report: report, mode: .clockTime, collapsedRecordIDs: [])
        let collapsed = TrajectoryProjection.make(report: report, mode: .order, collapsedRecordIDs: [request.id])
        let collapsedTurn = TrajectoryProjection.make(report: report, mode: .order, collapsedRecordIDs: [turn.id])

        #expect(order.records.map { $0.id } == [turn.id, request.id, tool.id])
        #expect(order.records.first { $0.id == request.id }?.parentID == turn.id)
        #expect(order.records.first { $0.id == request.id }?.depth == 1)
        #expect(order.records.last?.depth == 2)
        #expect(order.records.last?.lane == .tools)
        #expect(order.records.last?.axisEnd == nil)
        #expect(active.axisLowerBound == 0)
        #expect(clock.axisUpperBound > clock.axisLowerBound)
        #expect(collapsed.records.map { $0.id } == [turn.id, request.id])
        #expect(Set(collapsed.records.map { $0.id }).isSubset(of: Set(order.records.map { $0.id })))
        #expect(collapsedTurn.records.map { $0.id } == [turn.id])
    }

    @Test func projectionReportsOrphansCyclesUnscopedAndInclusiveOverlap() throws {
        let turn = try makeTurn(start: 0, end: 10_000)
        let orphan = try makeActivity(
            turnID: nil,
            kind: .tool,
            sourceID: "orphan",
            start: 20_000,
            end: 21_000,
            rawModelID: nil,
            toolName: "orphan"
        )
        let cycleA = try makeActivity(
            turnID: turn.id,
            parentActivityID: "codex:cycle-b",
            kind: .tool,
            sourceID: "cycle-a",
            start: 1_000,
            end: 2_000,
            rawModelID: nil,
            toolName: "a"
        )
        let cycleB = try makeActivity(
            turnID: turn.id,
            parentActivityID: cycleA.id,
            kind: .tool,
            sourceID: "cycle-b",
            start: 2_000,
            end: 3_000,
            rawModelID: nil,
            toolName: "b"
        )
        let report = makeReport(turns: [turn], activities: [orphan, cycleA, cycleB])
        let projection = TrajectoryProjection.make(report: report, mode: .activeTime, collapsedRecordIDs: [])

        #expect(projection.issues.contains { $0.kind == .missingTurn && $0.recordID == orphan.id })
        #expect(projection.issues.contains { $0.kind == .outsideActiveTime && $0.recordID == orphan.id })
        #expect(projection.issues.contains { $0.kind == .parentCycle })
        #expect(TrajectoryProjection.recordIDs(overlapping: 0...0, in: projection).contains(turn.id))
        #expect(!TrajectoryProjection.recordIDs(overlapping: 20...21, in: projection).contains(orphan.id))
    }

    @Test func storeRoundTripsTrajectoryAndRollsBackCheckpointWithBatch() async throws {
        let fixture = try TrajectoryFixture()
        let store = try UsageAnalyticsStore(databaseURL: fixture.databaseURL)
        let event = try makeEvent(sourceKey: "source-1", sessionKey: "session-1", sourceID: "event-1", occurredAt: 1_000)
        let unlinkedEvent = try makeEvent(sourceKey: "source-1", sessionKey: "session-1", sourceID: "event-2", occurredAt: 1_500)
        let turn = try makeTurn(
            agent: .pi,
            sessionKey: "session-1",
            sourceKey: "source-1",
            sourceID: "turn-1"
        )
        let activity = try makeActivity(
            agent: .pi,
            turnID: turn.id,
            kind: .modelRequest,
            sourceID: "request-1",
            sourceKey: "source-1",
            sessionKey: "session-1",
            rawModelID: "model-a",
            usageEventID: event.id
        )
        var batch = UsageImportBatch(agent: .pi)
        batch.events = [event, unlinkedEvent]
        batch.activeTurns = [turn]
        batch.activities = [activity]
        batch.trajectoryCapabilities = try TrajectoryCapabilityFamily.allCases.map {
            try TrajectoryCapability.normalized(
                agent: .pi,
                sessionKey: "session-1",
                sourceKey: "source-1",
                family: $0,
                availability: $0 == .turnTiming ? .complete : .unavailable,
                timingQuality: $0 == .turnTiming ? .exact : nil,
                sourceSchemaVersion: "fixture-v1",
                importerVersion: 3
            )
        }
        batch.checkpoints = [UsageImportCheckpoint(
            agent: .pi, sourceKey: "source-1", sourceIdentity: "identity-1",
            sourceSize: 1, modifiedAtMilliseconds: 1, byteOffset: 1,
            highWatermark: nil, importerVersion: 3
        )]

        try await store.apply(batch)
        try await store.apply(batch)
        let report = try #require(await store.trajectoryReport(sessionKey: "session-1"))
        #expect(try await store.trajectoryActivities(sessionKey: "session-1").count == 1)
        #expect(try await store.trajectoryCapabilities(sessionKey: "session-1").count == 7)
        #expect(report.linkedUsageEvents.map(\.id) == [event.id])
        #expect(try await store.checkpoints(for: .pi).count == 1)

        var secondSource = UsageImportBatch(agent: .pi)
        secondSource.events = [try makeEvent(
            sourceKey: "source-2", sessionKey: "session-2", sourceID: "event-3", occurredAt: 2_000
        )]
        secondSource.activeTurns = [try makeTurn(
            agent: .pi, sessionKey: "session-2", sourceKey: "source-2",
            sourceID: "turn-2", start: 2_000, end: 3_000
        )]
        secondSource.activities = [try makeActivity(
            agent: .pi,
            turnID: secondSource.activeTurns[0].id,
            kind: .modelRequest,
            sourceID: "request-2",
            sourceKey: "source-2",
            sessionKey: "session-2",
            rawModelID: "model-b"
        )]
        secondSource.trajectoryCapabilities = [try TrajectoryCapability.normalized(
            agent: .pi,
            sessionKey: "session-2",
            sourceKey: "source-2",
            family: .turnTiming,
            availability: .complete,
            timingQuality: .inferred,
            sourceSchemaVersion: "fixture-v1",
            importerVersion: 3
        )]
        secondSource.checkpoints = [UsageImportCheckpoint(
            agent: .pi, sourceKey: "source-2", sourceIdentity: "identity-2", sourceSize: 1,
            modifiedAtMilliseconds: 1, byteOffset: 1, highWatermark: nil, importerVersion: 3
        )]
        try await store.apply(secondSource)

        var removal = UsageImportBatch(agent: .pi)
        removal.removedSourceKeys = ["source-2"]
        try await store.apply(removal)
        #expect(try await store.events(sessionKeys: ["session-2"]).isEmpty)
        #expect(try await store.activeTurns(sessionKeys: ["session-2"]).isEmpty)
        #expect(try await store.trajectoryActivities(sessionKey: "session-2").isEmpty)
        #expect(try await store.trajectoryCapabilities(sessionKey: "session-2").isEmpty)

        var invalid = UsageImportBatch(agent: .pi)
        invalid.events = [try makeEvent(sourceKey: "source-2", sessionKey: "session-2", sourceID: "event-2", occurredAt: 2_000)]
        invalid.checkpoints = [UsageImportCheckpoint(
            agent: .pi, sourceKey: "", sourceIdentity: "identity-2", sourceSize: 1,
            modifiedAtMilliseconds: 1, byteOffset: 1, highWatermark: nil, importerVersion: 3
        )]
        await #expect(throws: UsageAnalyticsStoreError.self) {
            try await store.apply(invalid)
        }
        #expect(try await store.events(agents: [.pi]).count == 2)
        #expect(try await store.checkpoints(for: .pi).count == 1)
    }

    @Test func schemaThreeMigrationAddsTrajectoryTablesAndPreservesRows() async throws {
        let fixture = try TrajectoryFixture()
        let schemaThreeStore = try UsageAnalyticsStore(databaseURL: fixture.databaseURL)
        var batch = UsageImportBatch(agent: .pi)
        batch.events = [try makeEvent(
            sourceKey: "source-1",
            sessionKey: "session-1",
            sourceID: "event-1"
        )]
        batch.activeTurns = [try makeTurn(
            agent: .pi,
            sessionKey: "session-1",
            sourceKey: "source-1",
            sourceID: "turn-1"
        )]
        batch.checkpoints = [UsageImportCheckpoint(
            agent: .pi,
            sourceKey: "source-1",
            sourceIdentity: "identity-1",
            sourceSize: 1,
            modifiedAtMilliseconds: 1,
            byteOffset: 1,
            highWatermark: nil,
            importerVersion: 3
        )]
        try await schemaThreeStore.apply(batch)
        try downgradeToSchemaThree(at: fixture.databaseURL)

        let migratedStore = try UsageAnalyticsStore(databaseURL: fixture.databaseURL)

        #expect(try databaseInteger(at: fixture.databaseURL, sql: "PRAGMA user_version") == UsageAnalyticsStore.schemaVersion)
        #expect(try await migratedStore.events(sessionKeys: ["session-1"]).count == 1)
        #expect(try await migratedStore.activeTurns(sessionKeys: ["session-1"]).count == 1)
        #expect(try await migratedStore.checkpoints(for: .pi).count == 1)
        #expect(try databaseInteger(at: fixture.databaseURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'trajectory_activity'") == 1)
        #expect(try databaseInteger(at: fixture.databaseURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'trajectory_capability'") == 1)

        let freshFixture = try TrajectoryFixture()
        let freshStore = try UsageAnalyticsStore(databaseURL: freshFixture.databaseURL)
        _ = freshStore
        #expect(
            try trajectorySchemaObjects(at: fixture.databaseURL)
                == trajectorySchemaObjects(at: freshFixture.databaseURL)
        )
    }

    @Test func sessionPaginationUsesStableKeysetAndExplicitUsageLinksOnly() async throws {
        let fixture = try TrajectoryFixture()
        let store = try UsageAnalyticsStore(databaseURL: fixture.databaseURL)
        var batch = UsageImportBatch(agent: .pi)
        batch.events = [
            try makeEvent(sourceKey: "source-a", sessionKey: "session-a", sourceID: "event-a", occurredAt: 3_000),
            try makeEvent(sourceKey: "source-b", sessionKey: "session-b", sourceID: "event-b", occurredAt: 2_000),
        ]
        batch.activeTurns = [
            try makeTurn(agent: .pi, sessionKey: "session-a", sourceKey: "source-a", sourceID: "turn-a", start: 3_000, end: 4_000),
            try makeTurn(agent: .pi, sessionKey: "session-b", sourceKey: "source-b", sourceID: "turn-b", start: 2_000, end: 3_000),
        ]
        batch.checkpoints = [
            UsageImportCheckpoint(agent: .pi, sourceKey: "source-a", sourceIdentity: "a", sourceSize: 1, modifiedAtMilliseconds: 1, byteOffset: 1, highWatermark: nil, importerVersion: 3),
            UsageImportCheckpoint(agent: .pi, sourceKey: "source-b", sourceIdentity: "b", sourceSize: 1, modifiedAtMilliseconds: 1, byteOffset: 1, highWatermark: nil, importerVersion: 3),
        ]
        try await store.apply(batch)

        let first = try await store.trajectorySessions(
            period: .all, agents: [.pi], before: nil, limit: 1,
            endingAt: Date(timeIntervalSince1970: 10), calendar: Calendar(identifier: .gregorian)
        )
        var leading = UsageImportBatch(agent: .pi)
        leading.events = [try makeEvent(
            sourceKey: "source-leading",
            sessionKey: "session-leading",
            sourceID: "event-leading",
            occurredAt: 5_000
        )]
        leading.activeTurns = [try makeTurn(
            agent: .pi,
            sessionKey: "session-leading",
            sourceKey: "source-leading",
            sourceID: "turn-leading",
            start: 5_000,
            end: 6_000
        )]
        try await store.apply(leading)
        let second = try await store.trajectorySessions(
            period: .all, agents: [.pi], before: first.nextCursor, limit: 1,
            endingAt: Date(timeIntervalSince1970: 10), calendar: Calendar(identifier: .gregorian)
        )

        #expect(first.sessions.map(\.sessionKey) == ["session-a"])
        #expect(first.sessions.first?.modelIDs == ["model-a"])
        #expect(second.sessions.map(\.sessionKey) == ["session-b"])
        await #expect(throws: UsageAnalyticsStoreError.self) {
            try await store.trajectorySessions(
                period: .all, agents: [.pi], before: nil, limit: 201,
                endingAt: Date(timeIntervalSince1970: 10), calendar: Calendar(identifier: .gregorian)
            )
        }
    }

    @MainActor
    @Test func modelNeverShowsAReportForAStaleOrClearedSelection() async throws {
        let fixture = try TrajectoryFixture()
        let store = try UsageAnalyticsStore(databaseURL: fixture.databaseURL)
        var batch = UsageImportBatch(agent: .pi)
        batch.events = [try makeEvent(
            sourceKey: "source-a",
            sessionKey: "session-a",
            sourceID: "event-a"
        )]
        batch.activeTurns = [try makeTurn(
            agent: .pi,
            sessionKey: "session-a",
            sourceKey: "source-a",
            sourceID: "turn-a"
        )]
        try await store.apply(batch)
        let model = TrajectoryModel(backend: TrajectoryBackend(store: store))

        await model.selectSession("session-a")
        #expect(model.report?.summary.sessionKey == "session-a")

        await model.selectSession("missing-session")
        #expect(model.selectedSessionKey == "missing-session")
        #expect(model.report == nil)
        #expect(model.errorMessage == "The selected session has no indexed metadata.")

        await model.selectSession(nil)
        #expect(model.selectedSessionKey == nil)
        #expect(model.report == nil)
        #expect(model.errorMessage == nil)
    }
}

private func makeActivity(
    agent: UsageAgent = .codex,
    turnID: String? = "codex:turn-1",
    parentActivityID: String? = nil,
    kind: TrajectoryActivityKind,
    status: TrajectoryActivityStatus = .succeeded,
    sourceID: String,
    sourceKey: String = "source-1",
    sessionKey: String = "session-1",
    start: Int64 = 1_000,
    end: Int64? = 2_000,
    rawModelID: String? = "model-a",
    toolName: String? = nil,
    attempt: Int? = nil,
    usageEventID: String? = nil
) throws -> TrajectoryActivity {
    try TrajectoryActivity.normalized(
        agent: agent,
        sessionKey: sessionKey,
        turnID: turnID,
        parentActivityID: parentActivityID,
        kind: kind,
        status: status,
        sourceOrder: 1,
        orderQuality: .sourceSequence,
        startedAtMilliseconds: start,
        endedAtMilliseconds: end,
        firstOutputAtMilliseconds: nil,
        startQuality: .exact,
        endQuality: end == nil ? nil : .exact,
        firstOutputQuality: nil,
        rawModelID: rawModelID,
        toolName: toolName,
        attempt: attempt,
        failureCategory: nil,
        usageEventID: usageEventID,
        sourceKey: sourceKey,
        sourceID: sourceID,
        sourceSchemaVersion: "fixture-v1",
        importerVersion: 3
    )
}

private func makeTurn(
    agent: UsageAgent = .codex,
    sessionKey: String = "session-1",
    sourceKey: String = "source-1",
    sourceID: String = "turn-1",
    start: Int64 = 1_000,
    end: Int64 = 10_000
) throws -> UsageActiveTurn {
    try UsageActiveTurn.normalized(
        agent: agent,
        sessionKey: sessionKey,
        pricingAuthority: .openAI,
        rawModelID: "model-a",
        canonicalModelID: "model-a",
        startedAtMilliseconds: start,
        endedAtMilliseconds: end,
        timingQuality: .exact,
        sourceKey: sourceKey,
        sourceID: sourceID,
        importerVersion: 3
    )
}

private func makeEvent(
    sourceKey: String,
    sessionKey: String,
    sourceID: String,
    occurredAt: Int64 = 1_000
) throws -> UsageEvent {
    try UsageEvent.normalized(
        agent: .pi,
        pricingAuthority: .openAI,
        rawProviderID: "fixture-provider",
        rawModelID: "model-a",
        canonicalModelID: "model-a",
        occurredAtMilliseconds: occurredAt,
        inputTokens: 1,
        cacheWriteTokens: 0,
        cacheReadTokens: 0,
        outputTokens: 1,
        sourceTotalTokens: 2,
        sourceKey: sourceKey,
        sessionKey: sessionKey,
        sourceID: sourceID,
        sourceSchemaVersion: "fixture-v1",
        importerVersion: 3
    )
}

private func makeReport(
    turns: [UsageActiveTurn],
    activities: [TrajectoryActivity],
    linkedUsageEvents: [UsageEvent] = []
) -> TrajectorySessionReport {
    let start = min(
        turns.map(\.startedAtMilliseconds).min() ?? Int64.max,
        activities.map(\.startedAtMilliseconds).min() ?? Int64.max
    )
    let end = max(
        turns.map(\.endedAtMilliseconds).max() ?? Int64.min,
        activities.compactMap { $0.endedAtMilliseconds ?? $0.startedAtMilliseconds }.max() ?? Int64.min
    )
    let sessionKey = turns.first?.sessionKey ?? activities.first?.sessionKey ?? "session-1"
    let agent = turns.first?.agent ?? activities.first?.agent ?? .codex
    let models = Set(turns.map { $0.canonicalModelID ?? $0.rawModelID } + activities.compactMap(\.rawModelID)).sorted()
    let summary = TrajectorySessionSummary(
        sessionKey: sessionKey,
        agent: agent,
        startedAtMilliseconds: start,
        endedAtMilliseconds: end,
        turnCount: turns.count,
        activityCount: activities.count,
        usageEventCount: linkedUsageEvents.count,
        modelIDs: models
    )
    return TrajectorySessionReport(
        summary: summary,
        turns: turns,
        activities: activities,
        capabilities: [],
        linkedUsageEvents: linkedUsageEvents
    )
}

private final class TrajectoryFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TrajectoryTests-\(UUID().uuidString)")
        databaseURL = root.appendingPathComponent("analytics.sqlite3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private func downgradeToSchemaThree(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw UsageAnalyticsStoreError.invalidDatabasePath
    }
    defer { sqlite3_close(database) }
    let sql = """
    DROP TABLE trajectory_activity;
    DROP TABLE trajectory_capability;
    PRAGMA user_version = 3;
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw UsageAnalyticsStoreError.sqlite("schema fixture")
    }
}

private func trajectorySchemaObjects(at url: URL) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw UsageAnalyticsStoreError.invalidDatabasePath
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    let sql = """
    SELECT type || ':' || name || ':' || COALESCE(sql, '')
    FROM sqlite_master
    WHERE name LIKE 'trajectory_%'
    ORDER BY type, name
    """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw UsageAnalyticsStoreError.sqlite("schema query")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let value = sqlite3_column_text(statement, 0) else { continue }
        rows.append(String(cString: value))
    }
    return rows
}

private func databaseInteger(at url: URL, sql: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw UsageAnalyticsStoreError.invalidDatabasePath
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw UsageAnalyticsStoreError.sqlite("schema query")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw UsageAnalyticsStoreError.sqlite("schema query row")
    }
    return Int(sqlite3_column_int64(statement, 0))
}
