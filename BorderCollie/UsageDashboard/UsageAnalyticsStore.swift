import Foundation
import SQLite3

enum UsageAnalyticsStoreError: Error, Equatable {
    case sqlite(String)
    case invalidDatabasePath
    case invalidStoredValue(column: String, value: String)
    case batchAgentMismatch
}

actor UsageAnalyticsStore {
    static let schemaVersion = 4

    private let database: OpaquePointer

    init(databaseURL: URL = UsageAnalyticsStore.defaultDatabaseURL()) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw UsageAnalyticsStoreError.invalidDatabasePath
        }
        database = handle

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            try Self.execute(database, "PRAGMA foreign_keys = ON")
            try Self.execute(database, "PRAGMA journal_mode = WAL")
            try Self.migrate(database)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    static func defaultDatabaseURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("BorderCollie/usage-analytics.sqlite3")
    }

    func checkpoints(for agent: UsageAgent) throws -> [String: UsageImportCheckpoint] {
        let sql = """
        SELECT source_key, source_identity, source_size, modified_at_ms, byte_offset,
               high_watermark, importer_version
        FROM import_checkpoint WHERE agent = ?1
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement)

        var result: [String: UsageImportCheckpoint] = [:]
        while try step(statement) {
            let sourceKey = text(statement, 0)
            result[sourceKey] = UsageImportCheckpoint(
                agent: agent,
                sourceKey: sourceKey,
                sourceIdentity: text(statement, 1),
                sourceSize: sqlite3_column_int64(statement, 2),
                modifiedAtMilliseconds: sqlite3_column_int64(statement, 3),
                byteOffset: sqlite3_column_int64(statement, 4),
                highWatermark: nullableText(statement, 5),
                importerVersion: Int(sqlite3_column_int64(statement, 6))
            )
        }
        return result
    }

    func apply(_ batch: UsageImportBatch) throws {
        guard batch.events.allSatisfy({ $0.agent == batch.agent }),
              batch.activeTurns.allSatisfy({ $0.agent == batch.agent }),
              batch.activities.allSatisfy({ $0.agent == batch.agent }),
              batch.trajectoryCapabilities.allSatisfy({ $0.agent == batch.agent }),
              batch.checkpoints.allSatisfy({ $0.agent == batch.agent })
        else { throw UsageAnalyticsStoreError.batchAgentMismatch }

        try transaction {
            for sourceKey in batch.resetSourceKeys.union(batch.removedSourceKeys) {
                try deleteEvents(agent: batch.agent, sourceKey: sourceKey)
                try deleteActiveTurns(agent: batch.agent, sourceKey: sourceKey)
                try deleteTrajectoryActivities(agent: batch.agent, sourceKey: sourceKey)
                try deleteTrajectoryCapabilities(agent: batch.agent, sourceKey: sourceKey)
                try deleteCheckpoint(agent: batch.agent, sourceKey: sourceKey)
            }
            for event in batch.events { try upsert(event) }
            for turn in batch.activeTurns { try upsert(turn) }
            for activity in batch.activities { try upsert(activity) }
            for capability in batch.trajectoryCapabilities { try upsert(capability) }
            for checkpoint in batch.checkpoints { try upsert(checkpoint) }
        }
    }

    func replacePricingCatalog(rules: [UsagePricingRule], aliases: [UsageModelAlias]) throws {
        try transaction {
            try Self.execute(database, "DELETE FROM pricing_rule")
            try Self.execute(database, "DELETE FROM model_alias")
            for rule in rules { try insert(rule) }
            for alias in aliases { try insert(alias) }
            try Self.execute(database, """
            UPDATE usage_event
            SET canonical_model_id = (
                SELECT model_alias.canonical_model_id
                FROM model_alias
                WHERE model_alias.authority = usage_event.pricing_authority
                  AND model_alias.raw_model_id = usage_event.raw_model_id
                  AND usage_event.occurred_at_ms >= model_alias.effective_from_ms
                  AND (model_alias.effective_until_ms IS NULL
                       OR usage_event.occurred_at_ms < model_alias.effective_until_ms)
            )
            WHERE EXISTS (
                SELECT 1 FROM model_alias
                WHERE model_alias.authority = usage_event.pricing_authority
                  AND model_alias.raw_model_id = usage_event.raw_model_id
                  AND usage_event.occurred_at_ms >= model_alias.effective_from_ms
                  AND (model_alias.effective_until_ms IS NULL
                       OR usage_event.occurred_at_ms < model_alias.effective_until_ms)
            )
            """)
            try Self.execute(database, """
            UPDATE usage_active_turn
            SET canonical_model_id = (
                SELECT model_alias.canonical_model_id
                FROM model_alias
                WHERE model_alias.authority = usage_active_turn.pricing_authority
                  AND model_alias.raw_model_id = usage_active_turn.raw_model_id
                  AND usage_active_turn.started_at_ms >= model_alias.effective_from_ms
                  AND (model_alias.effective_until_ms IS NULL
                       OR usage_active_turn.started_at_ms < model_alias.effective_until_ms)
            )
            WHERE EXISTS (
                SELECT 1 FROM model_alias
                WHERE model_alias.authority = usage_active_turn.pricing_authority
                  AND model_alias.raw_model_id = usage_active_turn.raw_model_id
                  AND usage_active_turn.started_at_ms >= model_alias.effective_from_ms
                  AND (model_alias.effective_until_ms IS NULL
                       OR usage_active_turn.started_at_ms < model_alias.effective_until_ms)
            )
            """)
        }
    }

    func fetchPricingRules() throws -> [UsagePricingRule] {
        let statement = try prepare("""
        SELECT id, authority, canonical_model_id, effective_from_ms, effective_until_ms,
               input_rate, cache_write_rate, cache_write_5m_rate, cache_write_1h_rate,
               cache_read_rate, output_rate, long_context_threshold,
               long_input_num, long_input_den, long_output_num, long_output_den,
               source_url, retrieved_at_ms
        FROM pricing_rule ORDER BY authority, canonical_model_id, effective_from_ms
        """)
        defer { sqlite3_finalize(statement) }
        var rules: [UsagePricingRule] = []
        while try step(statement) {
            let rawAuthority = text(statement, 1)
            guard let authority = PricingAuthority(rawValue: rawAuthority) else {
                throw UsageAnalyticsStoreError.invalidStoredValue(column: "authority", value: rawAuthority)
            }
            rules.append(UsagePricingRule(
                id: text(statement, 0),
                authority: authority,
                canonicalModelID: text(statement, 2),
                effectiveFromMilliseconds: sqlite3_column_int64(statement, 3),
                effectiveUntilMilliseconds: nullableInt64(statement, 4),
                inputRateNanodollarsPerToken: sqlite3_column_int64(statement, 5),
                cacheWriteRateNanodollarsPerToken: nullableInt64(statement, 6),
                cacheWrite5mRateNanodollarsPerToken: nullableInt64(statement, 7),
                cacheWrite1hRateNanodollarsPerToken: nullableInt64(statement, 8),
                cacheReadRateNanodollarsPerToken: sqlite3_column_int64(statement, 9),
                outputRateNanodollarsPerToken: sqlite3_column_int64(statement, 10),
                longContextThresholdTokens: nullableInt64(statement, 11),
                longContextInputMultiplierNumerator: sqlite3_column_int64(statement, 12),
                longContextInputMultiplierDenominator: sqlite3_column_int64(statement, 13),
                longContextOutputMultiplierNumerator: sqlite3_column_int64(statement, 14),
                longContextOutputMultiplierDenominator: sqlite3_column_int64(statement, 15),
                sourceURL: text(statement, 16),
                retrievedAtMilliseconds: sqlite3_column_int64(statement, 17)
            ))
        }
        return rules
    }

    func updatePricing(eventID: String, result: UsagePricingResult) throws {
        let statement = try prepare("UPDATE usage_event SET estimated_cost_nanos = ?1, pricing_rule_id = ?2 WHERE id = ?3")
        defer { sqlite3_finalize(statement) }
        switch result {
        case let .priced(cost, ruleID):
            bind(cost, to: 1, in: statement)
            bind(ruleID, to: 2, in: statement)
        case .unavailable:
            sqlite3_bind_null(statement, 1)
            sqlite3_bind_null(statement, 2)
        }
        bind(eventID, to: 3, in: statement)
        try requireDone(statement)
    }

    func updatePricing(_ results: [String: UsagePricingResult]) throws {
        try transaction {
            for (eventID, result) in results {
                try updatePricing(eventID: eventID, result: result)
            }
        }
    }

    func events(
        interval: DateInterval? = nil,
        agents: Set<UsageAgent>? = nil,
        sessionKeys: Set<String>? = nil
    ) throws -> [UsageEvent] {
        if let agents, agents.isEmpty || sessionKeys?.isEmpty == true {
            return []
        }
        var clauses: [String] = []
        if interval != nil { clauses.append("occurred_at_ms >= ? AND occurred_at_ms < ?") }
        if let agents, !agents.isEmpty {
            clauses.append("agent IN (\(Array(repeating: "?", count: agents.count).joined(separator: ",")))")
        }
        if let sessionKeys, !sessionKeys.isEmpty {
            clauses.append("session_key IN (\(Array(repeating: "?", count: sessionKeys.count).joined(separator: ",")))")
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare(Self.eventSelect + whereSQL + " ORDER BY occurred_at_ms, id")
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let interval {
            bind(UsageEpoch.milliseconds(interval.start), to: index, in: statement); index += 1
            bind(UsageEpoch.milliseconds(interval.end), to: index, in: statement); index += 1
        }
        if let agents, !agents.isEmpty {
            for agent in agents.sorted(by: { $0.rawValue < $1.rawValue }) {
                bind(agent.rawValue, to: index, in: statement); index += 1
            }
        }
        if let sessionKeys, !sessionKeys.isEmpty {
            for sessionKey in sessionKeys.sorted() {
                bind(sessionKey, to: index, in: statement); index += 1
            }
        }

        var events: [UsageEvent] = []
        while try step(statement) { events.append(try decodeEvent(statement)) }
        return events
    }

    func activeTurns(
        interval: DateInterval? = nil,
        agents: Set<UsageAgent>? = nil,
        sessionKeys: Set<String>? = nil
    ) throws -> [UsageActiveTurn] {
        if let agents, agents.isEmpty || sessionKeys?.isEmpty == true {
            return []
        }
        var clauses: [String] = []
        if interval != nil { clauses.append("ended_at_ms > ? AND started_at_ms < ?") }
        if let agents, !agents.isEmpty {
            clauses.append("agent IN (\(Array(repeating: "?", count: agents.count).joined(separator: ",")))")
        }
        if let sessionKeys, !sessionKeys.isEmpty {
            clauses.append("session_key IN (\(Array(repeating: "?", count: sessionKeys.count).joined(separator: ",")))")
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare(Self.activeTurnSelect + whereSQL + " ORDER BY started_at_ms, id")
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let interval {
            bind(UsageEpoch.milliseconds(interval.start), to: index, in: statement); index += 1
            bind(UsageEpoch.milliseconds(interval.end), to: index, in: statement); index += 1
        }
        if let agents, !agents.isEmpty {
            for agent in agents.sorted(by: { $0.rawValue < $1.rawValue }) {
                bind(agent.rawValue, to: index, in: statement); index += 1
            }
        }
        if let sessionKeys, !sessionKeys.isEmpty {
            for sessionKey in sessionKeys.sorted() {
                bind(sessionKey, to: index, in: statement); index += 1
            }
        }

        var turns: [UsageActiveTurn] = []
        while try step(statement) { turns.append(try decodeActiveTurn(statement)) }
        return turns
    }

    func trajectoryActivities(
        sessionKey: String? = nil,
        agents: Set<UsageAgent>? = nil
    ) throws -> [TrajectoryActivity] {
        var clauses: [String] = []
        if sessionKey != nil { clauses.append("session_key = ?") }
        if let agents, agents.isEmpty { return [] }
        if let agents, !agents.isEmpty {
            clauses.append("agent IN (\(Array(repeating: "?", count: agents.count).joined(separator: ",")))")
        }
        let sql = Self.trajectoryActivitySelect
            + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))
            + " ORDER BY session_key, source_order, started_at_ms, id"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let sessionKey { bind(sessionKey, to: index, in: statement); index += 1 }
        if let agents, !agents.isEmpty {
            for agent in agents.sorted(by: { $0.rawValue < $1.rawValue }) {
                bind(agent.rawValue, to: index, in: statement)
                index += 1
            }
        }
        var activities: [TrajectoryActivity] = []
        while try step(statement) { activities.append(try decodeTrajectoryActivity(statement)) }
        return activities
    }

    func trajectoryCapabilities(sessionKey: String? = nil) throws -> [TrajectoryCapability] {
        let statement = try prepare("""
        SELECT agent, session_key, source_key, family, availability, timing_quality,
               source_schema_version, importer_version
        FROM trajectory_capability
        \(sessionKey == nil ? "" : "WHERE session_key = ?1")
        ORDER BY session_key, family
        """)
        defer { sqlite3_finalize(statement) }
        if let sessionKey { bind(sessionKey, to: 1, in: statement) }
        var capabilities: [TrajectoryCapability] = []
        while try step(statement) { capabilities.append(try decodeTrajectoryCapability(statement)) }
        return capabilities
    }

    func trajectorySessions(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        before cursor: TrajectorySessionCursor?,
        limit: Int,
        endingAt date: Date,
        calendar: Calendar
    ) throws -> TrajectorySessionPage {
        guard (1...200).contains(limit) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory.limit", value: String(limit))
        }
        guard !agents.isEmpty else { return TrajectorySessionPage(sessions: [], nextCursor: nil) }
        let interval = period.interval(endingAt: date, calendar: calendar)
        let sortedAgents = agents.sorted { $0.rawValue < $1.rawValue }
        let agentPlaceholders = Array(repeating: "?", count: sortedAgents.count).joined(separator: ",")
        var summaryClauses: [String] = []
        if interval != nil {
            summaryClauses.append("started_at_ms < ? AND ended_at_ms >= ?")
        }
        if cursor != nil {
            summaryClauses.append("(started_at_ms < ? OR (started_at_ms = ? AND session_key < ?))")
        }
        let summaryWhere = summaryClauses.isEmpty ? "" : "WHERE " + summaryClauses.joined(separator: " AND ")
        let statement = try prepare("""
        WITH trajectory_records AS (
            SELECT session_key, agent,
                   occurred_at_ms AS started_at_ms, occurred_at_ms AS ended_at_ms,
                   0 AS turn_count, 0 AS activity_count, 1 AS event_count
            FROM usage_event
            WHERE session_key IS NOT NULL AND agent IN (\(agentPlaceholders))
            UNION ALL
            SELECT session_key, agent, started_at_ms, ended_at_ms,
                   1 AS turn_count, 0 AS activity_count, 0 AS event_count
            FROM usage_active_turn
            WHERE agent IN (\(agentPlaceholders))
            UNION ALL
            SELECT session_key, agent, started_at_ms, COALESCE(ended_at_ms, started_at_ms),
                   0 AS turn_count, 1 AS activity_count, 0 AS event_count
            FROM trajectory_activity
            WHERE agent IN (\(agentPlaceholders))
        ), trajectory_sessions AS (
            SELECT session_key, agent,
                   MIN(started_at_ms) AS started_at_ms,
                   MAX(ended_at_ms) AS ended_at_ms,
                   SUM(turn_count) AS turn_count,
                   SUM(activity_count) AS activity_count,
                   SUM(event_count) AS event_count
            FROM trajectory_records
            GROUP BY agent, session_key
        )
        SELECT session_key, agent, started_at_ms, ended_at_ms,
               turn_count, activity_count, event_count
        FROM trajectory_sessions
        \(summaryWhere)
        ORDER BY started_at_ms DESC, session_key DESC
        LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for _ in 0..<3 {
            for agent in sortedAgents {
                bind(agent.rawValue, to: bindIndex, in: statement)
                bindIndex += 1
            }
        }
        if let interval {
            bind(UsageEpoch.milliseconds(interval.end), to: bindIndex, in: statement)
            bindIndex += 1
            bind(UsageEpoch.milliseconds(interval.start), to: bindIndex, in: statement)
            bindIndex += 1
        }
        if let cursor {
            bind(cursor.startedAtMilliseconds, to: bindIndex, in: statement)
            bindIndex += 1
            bind(cursor.startedAtMilliseconds, to: bindIndex, in: statement)
            bindIndex += 1
            bind(cursor.sessionKey, to: bindIndex, in: statement)
            bindIndex += 1
        }
        bind(Int64(limit + 1), to: bindIndex, in: statement)

        var summaries: [TrajectorySessionSummary] = []
        while try step(statement) {
            let rawAgent = text(statement, 1)
            guard let agent = UsageAgent(rawValue: rawAgent) else {
                throw UsageAnalyticsStoreError.invalidStoredValue(
                    column: "trajectory.session.agent",
                    value: rawAgent
                )
            }
            summaries.append(TrajectorySessionSummary(
                sessionKey: text(statement, 0),
                agent: agent,
                startedAtMilliseconds: sqlite3_column_int64(statement, 2),
                endedAtMilliseconds: sqlite3_column_int64(statement, 3),
                turnCount: Int(sqlite3_column_int64(statement, 4)),
                activityCount: Int(sqlite3_column_int64(statement, 5)),
                usageEventCount: Int(sqlite3_column_int64(statement, 6)),
                modelIDs: []
            ))
        }

        let hasMore = summaries.count > limit
        if hasMore { summaries.removeLast() }
        let modelsBySession = try trajectoryModelIDs(sessionKeys: summaries.map(\.sessionKey))
        summaries = summaries.map { summary in
            TrajectorySessionSummary(
                sessionKey: summary.sessionKey,
                agent: summary.agent,
                startedAtMilliseconds: summary.startedAtMilliseconds,
                endedAtMilliseconds: summary.endedAtMilliseconds,
                turnCount: summary.turnCount,
                activityCount: summary.activityCount,
                usageEventCount: summary.usageEventCount,
                modelIDs: modelsBySession[summary.sessionKey, default: []]
            )
        }
        let nextCursor = hasMore ? summaries.last.map {
            TrajectorySessionCursor(
                startedAtMilliseconds: $0.startedAtMilliseconds,
                sessionKey: $0.sessionKey
            )
        } : nil
        return TrajectorySessionPage(sessions: summaries, nextCursor: nextCursor)
    }

    private func trajectoryModelIDs(sessionKeys: [String]) throws -> [String: [String]] {
        guard !sessionKeys.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: sessionKeys.count).joined(separator: ",")
        let statement = try prepare("""
        SELECT session_key, model_id
        FROM (
            SELECT session_key, COALESCE(canonical_model_id, raw_model_id) AS model_id
            FROM usage_event
            WHERE session_key IN (\(placeholders))
            UNION
            SELECT session_key, COALESCE(canonical_model_id, raw_model_id) AS model_id
            FROM usage_active_turn
            WHERE session_key IN (\(placeholders))
            UNION
            SELECT session_key, raw_model_id AS model_id
            FROM trajectory_activity
            WHERE session_key IN (\(placeholders))
        )
        WHERE model_id IS NOT NULL
        GROUP BY session_key, model_id
        ORDER BY session_key, model_id
        """)
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        for _ in 0..<3 {
            for sessionKey in sessionKeys {
                bind(sessionKey, to: bindIndex, in: statement)
                bindIndex += 1
            }
        }
        var modelsBySession: [String: [String]] = [:]
        while try step(statement) {
            modelsBySession[text(statement, 0), default: []].append(text(statement, 1))
        }
        return modelsBySession
    }

    func trajectoryReport(sessionKey: String) throws -> TrajectorySessionReport? {
        let turns = try activeTurns(sessionKeys: [sessionKey])
        let activities = try trajectoryActivities(sessionKey: sessionKey)
        let allEvents = try events(sessionKeys: [sessionKey])
        guard !turns.isEmpty || !activities.isEmpty || !allEvents.isEmpty else { return nil }

        let capabilityRows = try trajectoryCapabilities(sessionKey: sessionKey)
        let linkedIDs = Set(activities.compactMap(\.usageEventID))
        let linkedEvents = allEvents.filter { linkedIDs.contains($0.id) }
        let agent = turns.first?.agent ?? activities.first?.agent ?? allEvents.first?.agent ?? .pi
        var started = Int64.max
        var ended = Int64.min
        var turnCount = 0
        var activityCount = 0
        var eventCount = 0
        var models: Set<String> = []
        for turn in turns {
            started = min(started, turn.startedAtMilliseconds)
            ended = max(ended, turn.endedAtMilliseconds)
            turnCount += 1
            models.insert(turn.canonicalModelID ?? turn.rawModelID)
        }
        for activity in activities {
            let activityEnd = activity.endedAtMilliseconds ?? activity.startedAtMilliseconds
            started = min(started, activity.startedAtMilliseconds)
            ended = max(ended, activityEnd)
            activityCount += 1
            if let model = activity.rawModelID { models.insert(model) }
        }
        for event in allEvents {
            started = min(started, event.occurredAtMilliseconds)
            ended = max(ended, event.occurredAtMilliseconds)
            eventCount += 1
            models.insert(event.canonicalModelID ?? event.rawModelID)
        }
        let summary = TrajectorySessionSummary(
            sessionKey: sessionKey,
            agent: agent,
            startedAtMilliseconds: started,
            endedAtMilliseconds: ended,
            turnCount: turnCount,
            activityCount: activityCount,
            usageEventCount: eventCount,
            modelIDs: models.sorted()
        )
        return TrajectorySessionReport(
            summary: summary,
            turns: turns,
            activities: activities,
            capabilities: capabilityRows,
            linkedUsageEvents: linkedEvents
        )
    }

    func evaluationRuns() throws -> [EvaluationRun] {
        let statement = try prepare("""
        SELECT id, name, started_at_ms, ended_at_ms, created_at_ms
        FROM evaluation_run
        ORDER BY CASE WHEN ended_at_ms IS NULL THEN 0 ELSE 1 END, started_at_ms DESC
        """)
        defer { sqlite3_finalize(statement) }
        var runs: [EvaluationRun] = []
        while try step(statement) {
            runs.append(EvaluationRun(
                id: text(statement, 0),
                name: text(statement, 1),
                startedAtMilliseconds: sqlite3_column_int64(statement, 2),
                endedAtMilliseconds: nullableInt64(statement, 3),
                createdAtMilliseconds: sqlite3_column_int64(statement, 4)
            ))
        }
        return runs
    }

    func createEvaluationRun(
        name: String,
        startedAtMilliseconds: Int64,
        endedAtMilliseconds: Int64?,
        createdAtMilliseconds: Int64
    ) throws -> EvaluationRun {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "evaluation_run.name", value: name)
        }
        if let endedAtMilliseconds, endedAtMilliseconds < startedAtMilliseconds {
            throw UsageAnalyticsStoreError.invalidStoredValue(
                column: "evaluation_run.ended_at_ms",
                value: String(endedAtMilliseconds)
            )
        }
        let run = EvaluationRun(
            id: UUID().uuidString,
            name: trimmedName,
            startedAtMilliseconds: startedAtMilliseconds,
            endedAtMilliseconds: endedAtMilliseconds,
            createdAtMilliseconds: createdAtMilliseconds
        )
        let statement = try prepare("INSERT INTO evaluation_run VALUES (?1,?2,?3,?4,?5)")
        defer { sqlite3_finalize(statement) }
        bind([
            .text(run.id), .text(run.name), .integer(run.startedAtMilliseconds),
            .optionalInteger(run.endedAtMilliseconds), .integer(run.createdAtMilliseconds),
        ], in: statement)
        try requireDone(statement)
        return run
    }

    func finishEvaluationRun(id: String, endedAtMilliseconds: Int64) throws {
        let statement = try prepare("""
        UPDATE evaluation_run
        SET ended_at_ms = ?1
        WHERE id = ?2 AND ended_at_ms IS NULL AND started_at_ms <= ?1
        """)
        defer { sqlite3_finalize(statement) }
        bind(endedAtMilliseconds, to: 1, in: statement)
        bind(id, to: 2, in: statement)
        try requireDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "evaluation_run.id", value: id)
        }
    }

    func deleteEvaluationRun(id: String) throws {
        let statement = try prepare("DELETE FROM evaluation_run WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        try requireDone(statement)
    }

    func evaluationSessionKeys(runID: String) throws -> Set<String> {
        let statement = try prepare("SELECT session_key FROM evaluation_run_session WHERE run_id = ?1")
        defer { sqlite3_finalize(statement) }
        bind(runID, to: 1, in: statement)
        var keys: Set<String> = []
        while try step(statement) { keys.insert(text(statement, 0)) }
        return keys
    }

    func replaceEvaluationSessionKeys(runID: String, sessionKeys: Set<String>) throws {
        try transaction {
            let delete = try prepare("DELETE FROM evaluation_run_session WHERE run_id = ?1")
            defer { sqlite3_finalize(delete) }
            bind(runID, to: 1, in: delete)
            try requireDone(delete)

            for sessionKey in sessionKeys.sorted() {
                let insert = try prepare("INSERT INTO evaluation_run_session VALUES (?1,?2)")
                bind(runID, to: 1, in: insert)
                bind(sessionKey, to: 2, in: insert)
                do {
                    try requireDone(insert)
                    sqlite3_finalize(insert)
                } catch {
                    sqlite3_finalize(insert)
                    throw error
                }
            }
        }
    }

    func eventCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM usage_event")
        defer { sqlite3_finalize(statement) }
        _ = try step(statement)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static let eventSelect = """
    SELECT id, agent, pricing_authority, raw_provider_id, raw_model_id, canonical_model_id,
           occurred_at_ms, input_tokens, cache_write_tokens, cache_write_5m_tokens,
           cache_write_1h_tokens, cache_read_tokens, output_tokens, reasoning_output_tokens,
           total_tokens, source_total_tokens, source_reported_cost_nanos,
           estimated_cost_nanos, pricing_rule_id, completeness, incomplete_reason,
           source_key, session_key, source_id, source_schema_version, importer_version
    FROM usage_event
    """

    private static let activeTurnSelect = """
    SELECT id, agent, session_key, pricing_authority, raw_model_id, canonical_model_id,
           started_at_ms, ended_at_ms, timing_quality, source_key, source_id, importer_version
    FROM usage_active_turn
    """

    private static let trajectoryActivitySelect = """
    SELECT id, agent, session_key, turn_id, parent_activity_id, kind, status,
           source_order, order_quality, started_at_ms, ended_at_ms,
           first_output_at_ms, start_quality, end_quality, first_output_quality,
           raw_model_id, tool_name, attempt, failure_category, usage_event_id,
           source_key, source_id, source_schema_version, importer_version
    FROM trajectory_activity
    """

    private static func migrate(_ database: OpaquePointer) throws {
        let version = Int(sqlite3_user_version(database))
        guard version <= schemaVersion else {
            throw UsageAnalyticsStoreError.sqlite("Database schema is newer than this app")
        }
        var currentVersion = version
        if version == 0 {
            try execute(database, """
            CREATE TABLE IF NOT EXISTS usage_event (
                id TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                pricing_authority TEXT NOT NULL,
                raw_provider_id TEXT,
                raw_model_id TEXT NOT NULL,
                canonical_model_id TEXT,
                occurred_at_ms INTEGER NOT NULL,
                input_tokens INTEGER,
                cache_write_tokens INTEGER,
                cache_write_5m_tokens INTEGER,
                cache_write_1h_tokens INTEGER,
                cache_read_tokens INTEGER,
                output_tokens INTEGER,
                reasoning_output_tokens INTEGER,
                total_tokens INTEGER,
                source_total_tokens INTEGER,
                source_reported_cost_nanos INTEGER,
                estimated_cost_nanos INTEGER,
                pricing_rule_id TEXT,
                completeness TEXT NOT NULL,
                incomplete_reason TEXT,
                source_key TEXT NOT NULL CHECK(length(source_key) > 0),
                session_key TEXT,
                source_id TEXT NOT NULL,
                source_schema_version TEXT NOT NULL,
                importer_version INTEGER NOT NULL,
                UNIQUE(agent, source_id)
            )
            """)
            try execute(database, """
            CREATE TABLE IF NOT EXISTS import_checkpoint (
                agent TEXT NOT NULL,
                source_key TEXT NOT NULL CHECK(length(source_key) > 0),
                source_identity TEXT NOT NULL,
                source_size INTEGER NOT NULL,
                modified_at_ms INTEGER NOT NULL,
                byte_offset INTEGER NOT NULL,
                high_watermark TEXT,
                importer_version INTEGER NOT NULL,
                PRIMARY KEY(agent, source_key)
            )
            """)
            try execute(database, """
            CREATE TABLE IF NOT EXISTS pricing_rule (
                id TEXT PRIMARY KEY,
                authority TEXT NOT NULL,
                canonical_model_id TEXT NOT NULL,
                effective_from_ms INTEGER NOT NULL,
                effective_until_ms INTEGER,
                input_rate INTEGER NOT NULL,
                cache_write_rate INTEGER,
                cache_write_5m_rate INTEGER,
                cache_write_1h_rate INTEGER,
                cache_read_rate INTEGER NOT NULL,
                output_rate INTEGER NOT NULL,
                long_context_threshold INTEGER,
                long_input_num INTEGER NOT NULL,
                long_input_den INTEGER NOT NULL,
                long_output_num INTEGER NOT NULL,
                long_output_den INTEGER NOT NULL,
                source_url TEXT NOT NULL,
                retrieved_at_ms INTEGER NOT NULL
            )
            """)
            try execute(database, """
            CREATE TABLE IF NOT EXISTS model_alias (
                authority TEXT NOT NULL,
                raw_model_id TEXT NOT NULL,
                canonical_model_id TEXT NOT NULL,
                effective_from_ms INTEGER NOT NULL,
                effective_until_ms INTEGER,
                source_url TEXT NOT NULL,
                PRIMARY KEY(authority, raw_model_id, effective_from_ms)
            )
            """)
            try createEvaluationSchema(database)
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_time_agent ON usage_event(occurred_at_ms, agent)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_model_time ON usage_event(canonical_model_id, occurred_at_ms)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_source ON usage_event(agent, source_key)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_session_time ON usage_event(session_key, occurred_at_ms)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_completeness_time ON usage_event(completeness, occurred_at_ms)")
            try execute(database, "PRAGMA user_version = 3")
            currentVersion = 3
        } else if version == 1 {
            try execute(database, "DROP TABLE IF EXISTS model_alias")
            try execute(database, """
            CREATE TABLE model_alias (
                authority TEXT NOT NULL,
                raw_model_id TEXT NOT NULL,
                canonical_model_id TEXT NOT NULL,
                effective_from_ms INTEGER NOT NULL,
                effective_until_ms INTEGER,
                source_url TEXT NOT NULL,
                PRIMARY KEY(authority, raw_model_id, effective_from_ms)
            )
            """)
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_completeness_time ON usage_event(completeness, occurred_at_ms)")
            try execute(database, "PRAGMA user_version = 2")
            currentVersion = 2
        }
        if currentVersion == 1 || currentVersion == 2 {
            try execute(database, "ALTER TABLE usage_event ADD COLUMN session_key TEXT")
            try createEvaluationSchema(database)
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_session_time ON usage_event(session_key, occurred_at_ms)")
            try execute(database, "PRAGMA user_version = 3")
            currentVersion = 3
        }
        if currentVersion == 3 {
            try createTrajectorySchema(database)
            try execute(database, "PRAGMA user_version = 4")
        }
    }

    private static func createEvaluationSchema(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS usage_active_turn (
            id TEXT PRIMARY KEY,
            agent TEXT NOT NULL,
            session_key TEXT NOT NULL CHECK(length(session_key) > 0),
            pricing_authority TEXT NOT NULL,
            raw_model_id TEXT NOT NULL,
            canonical_model_id TEXT,
            started_at_ms INTEGER NOT NULL,
            ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms >= started_at_ms),
            timing_quality TEXT NOT NULL,
            source_key TEXT NOT NULL CHECK(length(source_key) > 0),
            source_id TEXT NOT NULL,
            importer_version INTEGER NOT NULL,
            UNIQUE(agent, source_id)
        )
        """)
        try execute(database, """
        CREATE TABLE IF NOT EXISTS evaluation_run (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL CHECK(length(trim(name)) > 0),
            started_at_ms INTEGER NOT NULL,
            ended_at_ms INTEGER CHECK(ended_at_ms IS NULL OR ended_at_ms >= started_at_ms),
            created_at_ms INTEGER NOT NULL
        )
        """)
        try execute(database, """
        CREATE TABLE IF NOT EXISTS evaluation_run_session (
            run_id TEXT NOT NULL REFERENCES evaluation_run(id) ON DELETE CASCADE,
            session_key TEXT NOT NULL CHECK(length(session_key) > 0),
            PRIMARY KEY(run_id, session_key)
        )
        """)
        try execute(database, "CREATE INDEX IF NOT EXISTS usage_active_turn_interval ON usage_active_turn(ended_at_ms, started_at_ms)")
        try execute(database, "CREATE INDEX IF NOT EXISTS usage_active_turn_session ON usage_active_turn(session_key, started_at_ms)")
        try execute(database, "CREATE INDEX IF NOT EXISTS usage_active_turn_source ON usage_active_turn(agent, source_key)")
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS evaluation_run_single_active ON evaluation_run((1)) WHERE ended_at_ms IS NULL")
    }

    private static func createTrajectorySchema(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS trajectory_activity (
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
        )
        """)
        try execute(database, """
        CREATE TABLE IF NOT EXISTS trajectory_capability (
            agent TEXT NOT NULL,
            session_key TEXT NOT NULL CHECK(length(session_key) > 0),
            source_key TEXT NOT NULL CHECK(length(source_key) > 0),
            family TEXT NOT NULL,
            availability TEXT NOT NULL,
            timing_quality TEXT,
            source_schema_version TEXT NOT NULL,
            importer_version INTEGER NOT NULL CHECK(importer_version > 0),
            PRIMARY KEY(agent, session_key, family)
        )
        """)
        try execute(database, "CREATE INDEX IF NOT EXISTS trajectory_activity_session_order ON trajectory_activity(session_key, source_order, started_at_ms)")
        try execute(database, "CREATE INDEX IF NOT EXISTS trajectory_activity_session_time ON trajectory_activity(session_key, started_at_ms, ended_at_ms)")
        try execute(database, "CREATE INDEX IF NOT EXISTS trajectory_activity_source ON trajectory_activity(agent, source_key)")
        try execute(database, "CREATE INDEX IF NOT EXISTS trajectory_activity_parent ON trajectory_activity(parent_activity_id)")
        try execute(database, "CREATE INDEX IF NOT EXISTS trajectory_capability_source ON trajectory_capability(agent, source_key)")
    }

    private func upsert(_ event: UsageEvent) throws {
        let sql = """
        INSERT INTO usage_event (
            id, agent, pricing_authority, raw_provider_id, raw_model_id, canonical_model_id,
            occurred_at_ms, input_tokens, cache_write_tokens, cache_write_5m_tokens,
            cache_write_1h_tokens, cache_read_tokens, output_tokens, reasoning_output_tokens,
            total_tokens, source_total_tokens, source_reported_cost_nanos, estimated_cost_nanos,
            pricing_rule_id, completeness, incomplete_reason, source_key, session_key,
            source_id, source_schema_version, importer_version
        ) VALUES (
            ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26
        ) ON CONFLICT(id) DO UPDATE SET
            pricing_authority=excluded.pricing_authority, raw_provider_id=excluded.raw_provider_id,
            raw_model_id=excluded.raw_model_id, canonical_model_id=excluded.canonical_model_id,
            occurred_at_ms=excluded.occurred_at_ms, input_tokens=excluded.input_tokens,
            cache_write_tokens=excluded.cache_write_tokens, cache_write_5m_tokens=excluded.cache_write_5m_tokens,
            cache_write_1h_tokens=excluded.cache_write_1h_tokens, cache_read_tokens=excluded.cache_read_tokens,
            output_tokens=excluded.output_tokens, reasoning_output_tokens=excluded.reasoning_output_tokens,
            total_tokens=excluded.total_tokens, source_total_tokens=excluded.source_total_tokens,
            source_reported_cost_nanos=excluded.source_reported_cost_nanos,
            estimated_cost_nanos=excluded.estimated_cost_nanos, pricing_rule_id=excluded.pricing_rule_id,
            completeness=excluded.completeness, incomplete_reason=excluded.incomplete_reason,
            source_key=excluded.source_key, session_key=excluded.session_key,
            source_schema_version=excluded.source_schema_version,
            importer_version=excluded.importer_version
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let values: [SQLiteValue] = [
            .text(event.id), .text(event.agent.rawValue), .text(event.pricingAuthority.rawValue),
            .optionalText(event.rawProviderID), .text(event.rawModelID), .optionalText(event.canonicalModelID),
            .integer(event.occurredAtMilliseconds), .optionalInteger(event.inputTokens),
            .optionalInteger(event.cacheWriteTokens), .optionalInteger(event.cacheWrite5mTokens),
            .optionalInteger(event.cacheWrite1hTokens), .optionalInteger(event.cacheReadTokens),
            .optionalInteger(event.outputTokens), .optionalInteger(event.reasoningOutputTokens),
            .optionalInteger(event.totalTokens), .optionalInteger(event.sourceTotalTokens),
            .optionalInteger(event.sourceReportedCostNanodollars), .optionalInteger(event.estimatedAPICostNanodollars),
            .optionalText(event.pricingRuleID), .text(event.completeness.rawValue),
            .optionalText(event.incompleteReason), .text(event.sourceKey), .optionalText(event.sessionKey),
            .text(event.sourceID), .text(event.sourceSchemaVersion),
            .integer(Int64(event.importerVersion)),
        ]
        bind(values, in: statement)
        try requireDone(statement)
    }

    private func upsert(_ turn: UsageActiveTurn) throws {
        let statement = try prepare("""
        INSERT INTO usage_active_turn VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
        ON CONFLICT(id) DO UPDATE SET
            session_key=excluded.session_key, pricing_authority=excluded.pricing_authority,
            raw_model_id=excluded.raw_model_id, canonical_model_id=excluded.canonical_model_id,
            started_at_ms=excluded.started_at_ms, ended_at_ms=excluded.ended_at_ms,
            timing_quality=excluded.timing_quality, source_key=excluded.source_key,
            importer_version=excluded.importer_version
        """)
        defer { sqlite3_finalize(statement) }
        bind([
            .text(turn.id), .text(turn.agent.rawValue), .text(turn.sessionKey),
            .text(turn.pricingAuthority.rawValue), .text(turn.rawModelID),
            .optionalText(turn.canonicalModelID), .integer(turn.startedAtMilliseconds),
            .integer(turn.endedAtMilliseconds), .text(turn.timingQuality.rawValue),
            .text(turn.sourceKey), .text(turn.sourceID), .integer(Int64(turn.importerVersion)),
        ], in: statement)
        try requireDone(statement)
    }

    private func upsert(_ activity: TrajectoryActivity) throws {
        let statement = try prepare("""
        INSERT INTO trajectory_activity (
            id, agent, session_key, turn_id, parent_activity_id, kind, status,
            source_order, order_quality, started_at_ms, ended_at_ms,
            first_output_at_ms, start_quality, end_quality, first_output_quality,
            raw_model_id, tool_name, attempt, failure_category, usage_event_id,
            source_key, source_id, source_schema_version, importer_version
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            agent=excluded.agent, session_key=excluded.session_key,
            turn_id=excluded.turn_id, parent_activity_id=excluded.parent_activity_id,
            kind=excluded.kind, status=excluded.status, source_order=excluded.source_order,
            order_quality=excluded.order_quality, started_at_ms=excluded.started_at_ms,
            ended_at_ms=excluded.ended_at_ms, first_output_at_ms=excluded.first_output_at_ms,
            start_quality=excluded.start_quality, end_quality=excluded.end_quality,
            first_output_quality=excluded.first_output_quality, raw_model_id=excluded.raw_model_id,
            tool_name=excluded.tool_name, attempt=excluded.attempt,
            failure_category=excluded.failure_category, usage_event_id=excluded.usage_event_id,
            source_key=excluded.source_key, source_schema_version=excluded.source_schema_version,
            importer_version=excluded.importer_version
        """)
        defer { sqlite3_finalize(statement) }
        bind([
            .text(activity.id), .text(activity.agent.rawValue), .text(activity.sessionKey),
            .optionalText(activity.turnID), .optionalText(activity.parentActivityID),
            .text(activity.kind.rawValue), .text(activity.status.rawValue),
            .integer(activity.sourceOrder), .text(activity.orderQuality.rawValue),
            .integer(activity.startedAtMilliseconds), .optionalInteger(activity.endedAtMilliseconds),
            .optionalInteger(activity.firstOutputAtMilliseconds), .text(activity.startQuality.rawValue),
            .optionalText(activity.endQuality?.rawValue), .optionalText(activity.firstOutputQuality?.rawValue),
            .optionalText(activity.rawModelID), .optionalText(activity.toolName),
            .optionalInteger(activity.attempt.map(Int64.init)), .optionalText(activity.failureCategory?.rawValue),
            .optionalText(activity.usageEventID), .text(activity.sourceKey), .text(activity.sourceID),
            .text(activity.sourceSchemaVersion), .integer(Int64(activity.importerVersion)),
        ], in: statement)
        try requireDone(statement)
    }

    private func upsert(_ capability: TrajectoryCapability) throws {
        let statement = try prepare("""
        INSERT INTO trajectory_capability (
            agent, session_key, source_key, family, availability, timing_quality,
            source_schema_version, importer_version
        ) VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(agent, session_key, family) DO UPDATE SET
            source_key=excluded.source_key, availability=excluded.availability,
            timing_quality=excluded.timing_quality,
            source_schema_version=excluded.source_schema_version,
            importer_version=excluded.importer_version
        """)
        defer { sqlite3_finalize(statement) }
        bind([
            .text(capability.agent.rawValue), .text(capability.sessionKey), .text(capability.sourceKey),
            .text(capability.family.rawValue), .text(capability.availability.rawValue),
            .optionalText(capability.timingQuality?.rawValue), .text(capability.sourceSchemaVersion),
            .integer(Int64(capability.importerVersion)),
        ], in: statement)
        try requireDone(statement)
    }

    private func upsert(_ checkpoint: UsageImportCheckpoint) throws {
        let statement = try prepare("""
        INSERT INTO import_checkpoint VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
        ON CONFLICT(agent, source_key) DO UPDATE SET
            source_identity=excluded.source_identity, source_size=excluded.source_size,
            modified_at_ms=excluded.modified_at_ms, byte_offset=excluded.byte_offset,
            high_watermark=excluded.high_watermark, importer_version=excluded.importer_version
        """)
        defer { sqlite3_finalize(statement) }
        bind([
            .text(checkpoint.agent.rawValue), .text(checkpoint.sourceKey), .text(checkpoint.sourceIdentity),
            .integer(checkpoint.sourceSize), .integer(checkpoint.modifiedAtMilliseconds),
            .integer(checkpoint.byteOffset), .optionalText(checkpoint.highWatermark),
            .integer(Int64(checkpoint.importerVersion)),
        ], in: statement)
        try requireDone(statement)
    }

    private func insert(_ rule: UsagePricingRule) throws {
        let statement = try prepare("INSERT INTO pricing_rule VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)")
        defer { sqlite3_finalize(statement) }
        bind([
            .text(rule.id), .text(rule.authority.rawValue), .text(rule.canonicalModelID),
            .integer(rule.effectiveFromMilliseconds), .optionalInteger(rule.effectiveUntilMilliseconds),
            .integer(rule.inputRateNanodollarsPerToken), .optionalInteger(rule.cacheWriteRateNanodollarsPerToken),
            .optionalInteger(rule.cacheWrite5mRateNanodollarsPerToken), .optionalInteger(rule.cacheWrite1hRateNanodollarsPerToken),
            .integer(rule.cacheReadRateNanodollarsPerToken), .integer(rule.outputRateNanodollarsPerToken),
            .optionalInteger(rule.longContextThresholdTokens), .integer(rule.longContextInputMultiplierNumerator),
            .integer(rule.longContextInputMultiplierDenominator), .integer(rule.longContextOutputMultiplierNumerator),
            .integer(rule.longContextOutputMultiplierDenominator), .text(rule.sourceURL),
            .integer(rule.retrievedAtMilliseconds),
        ], in: statement)
        try requireDone(statement)
    }

    private func insert(_ alias: UsageModelAlias) throws {
        let statement = try prepare("INSERT INTO model_alias VALUES (?1,?2,?3,?4,?5,?6)")
        defer { sqlite3_finalize(statement) }
        bind([
            .text(alias.authority.rawValue), .text(alias.rawModelID), .text(alias.canonicalModelID),
            .integer(alias.effectiveFromMilliseconds), .optionalInteger(alias.effectiveUntilMilliseconds),
            .text(alias.sourceURL),
        ], in: statement)
        try requireDone(statement)
    }

    private func deleteEvents(agent: UsageAgent, sourceKey: String) throws {
        let statement = try prepare("DELETE FROM usage_event WHERE agent=?1 AND source_key=?2")
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement); bind(sourceKey, to: 2, in: statement)
        try requireDone(statement)
    }

    private func deleteActiveTurns(agent: UsageAgent, sourceKey: String) throws {
        let statement = try prepare("DELETE FROM usage_active_turn WHERE agent=?1 AND source_key=?2")
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement); bind(sourceKey, to: 2, in: statement)
        try requireDone(statement)
    }

    private func deleteTrajectoryActivities(agent: UsageAgent, sourceKey: String) throws {
        let statement = try prepare("DELETE FROM trajectory_activity WHERE agent=?1 AND source_key=?2")
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement); bind(sourceKey, to: 2, in: statement)
        try requireDone(statement)
    }

    private func deleteTrajectoryCapabilities(agent: UsageAgent, sourceKey: String) throws {
        let statement = try prepare("DELETE FROM trajectory_capability WHERE agent=?1 AND source_key=?2")
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement); bind(sourceKey, to: 2, in: statement)
        try requireDone(statement)
    }

    private func deleteCheckpoint(agent: UsageAgent, sourceKey: String) throws {
        let statement = try prepare("DELETE FROM import_checkpoint WHERE agent=?1 AND source_key=?2")
        defer { sqlite3_finalize(statement) }
        bind(agent.rawValue, to: 1, in: statement); bind(sourceKey, to: 2, in: statement)
        try requireDone(statement)
    }

    private func decodeEvent(_ statement: OpaquePointer) throws -> UsageEvent {
        let rawAgent = text(statement, 1)
        let rawAuthority = text(statement, 2)
        let rawCompleteness = text(statement, 19)
        guard let agent = UsageAgent(rawValue: rawAgent) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "agent", value: rawAgent)
        }
        guard let authority = PricingAuthority(rawValue: rawAuthority) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "pricing_authority", value: rawAuthority)
        }
        guard let completeness = UsageCompleteness(rawValue: rawCompleteness) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "completeness", value: rawCompleteness)
        }
        return UsageEvent(
            id: text(statement, 0), agent: agent, pricingAuthority: authority,
            rawProviderID: nullableText(statement, 3), rawModelID: text(statement, 4),
            canonicalModelID: nullableText(statement, 5), occurredAtMilliseconds: sqlite3_column_int64(statement, 6),
            inputTokens: nullableInt64(statement, 7), cacheWriteTokens: nullableInt64(statement, 8),
            cacheWrite5mTokens: nullableInt64(statement, 9), cacheWrite1hTokens: nullableInt64(statement, 10),
            cacheReadTokens: nullableInt64(statement, 11), outputTokens: nullableInt64(statement, 12),
            reasoningOutputTokens: nullableInt64(statement, 13), totalTokens: nullableInt64(statement, 14),
            sourceTotalTokens: nullableInt64(statement, 15), sourceReportedCostNanodollars: nullableInt64(statement, 16),
            estimatedAPICostNanodollars: nullableInt64(statement, 17), pricingRuleID: nullableText(statement, 18),
            completeness: completeness, incompleteReason: nullableText(statement, 20), sourceKey: text(statement, 21),
            sessionKey: nullableText(statement, 22), sourceID: text(statement, 23),
            sourceSchemaVersion: text(statement, 24), importerVersion: Int(sqlite3_column_int64(statement, 25))
        )
    }

    private func decodeActiveTurn(_ statement: OpaquePointer) throws -> UsageActiveTurn {
        let rawAgent = text(statement, 1)
        let rawAuthority = text(statement, 3)
        let rawQuality = text(statement, 8)
        guard let agent = UsageAgent(rawValue: rawAgent) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "agent", value: rawAgent)
        }
        guard let authority = PricingAuthority(rawValue: rawAuthority) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "pricing_authority", value: rawAuthority)
        }
        guard let quality = UsageTimingQuality(rawValue: rawQuality) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "timing_quality", value: rawQuality)
        }
        return UsageActiveTurn(
            id: text(statement, 0),
            agent: agent,
            sessionKey: text(statement, 2),
            pricingAuthority: authority,
            rawModelID: text(statement, 4),
            canonicalModelID: nullableText(statement, 5),
            startedAtMilliseconds: sqlite3_column_int64(statement, 6),
            endedAtMilliseconds: sqlite3_column_int64(statement, 7),
            timingQuality: quality,
            sourceKey: text(statement, 9),
            sourceID: text(statement, 10),
            importerVersion: Int(sqlite3_column_int64(statement, 11))
        )
    }

    private func decodeTrajectoryActivity(_ statement: OpaquePointer) throws -> TrajectoryActivity {
        let rawAgent = text(statement, 1)
        let rawKind = text(statement, 5)
        let rawStatus = text(statement, 6)
        let rawOrderQuality = text(statement, 8)
        let rawStartQuality = text(statement, 12)
        guard let agent = UsageAgent(rawValue: rawAgent) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_activity.agent", value: rawAgent)
        }
        guard let kind = TrajectoryActivityKind(rawValue: rawKind) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_activity.kind", value: rawKind)
        }
        guard let status = TrajectoryActivityStatus(rawValue: rawStatus) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_activity.status", value: rawStatus)
        }
        guard let orderQuality = TrajectoryOrderQuality(rawValue: rawOrderQuality) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_activity.order_quality", value: rawOrderQuality)
        }
        guard let startQuality = TrajectoryBoundaryQuality(rawValue: rawStartQuality) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_activity.start_quality", value: rawStartQuality)
        }
        let endQuality = try decodeOptional(
            TrajectoryBoundaryQuality.self,
            statement: statement,
            index: 13,
            column: "trajectory_activity.end_quality"
        )
        let firstOutputQuality = try decodeOptional(
            TrajectoryBoundaryQuality.self,
            statement: statement,
            index: 14,
            column: "trajectory_activity.first_output_quality"
        )
        let failureCategory = try decodeOptional(
            TrajectoryFailureCategory.self,
            statement: statement,
            index: 18,
            column: "trajectory_activity.failure_category"
        )
        do {
            return try TrajectoryActivity.normalized(
                agent: agent,
                sessionKey: text(statement, 2),
                turnID: nullableText(statement, 3),
                parentActivityID: nullableText(statement, 4),
                kind: kind,
                status: status,
                sourceOrder: sqlite3_column_int64(statement, 7),
                orderQuality: orderQuality,
                startedAtMilliseconds: sqlite3_column_int64(statement, 9),
                endedAtMilliseconds: nullableInt64(statement, 10),
                firstOutputAtMilliseconds: nullableInt64(statement, 11),
                startQuality: startQuality,
                endQuality: endQuality,
                firstOutputQuality: firstOutputQuality,
                rawModelID: nullableText(statement, 15),
                toolName: nullableText(statement, 16),
                attempt: nullableInt64(statement, 17).map(Int.init),
                failureCategory: failureCategory,
                usageEventID: nullableText(statement, 19),
                sourceKey: text(statement, 20),
                sourceID: text(statement, 21),
                sourceSchemaVersion: text(statement, 22),
                importerVersion: Int(sqlite3_column_int64(statement, 23))
            )
        } catch {
            throw UsageAnalyticsStoreError.invalidStoredValue(
                column: "trajectory_activity",
                value: String(describing: error)
            )
        }
    }

    private func decodeTrajectoryCapability(_ statement: OpaquePointer) throws -> TrajectoryCapability {
        let rawAgent = text(statement, 0)
        let rawFamily = text(statement, 3)
        let rawAvailability = text(statement, 4)
        guard let agent = UsageAgent(rawValue: rawAgent) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_capability.agent", value: rawAgent)
        }
        guard let family = TrajectoryCapabilityFamily(rawValue: rawFamily) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_capability.family", value: rawFamily)
        }
        guard let availability = TrajectoryCapabilityAvailability(rawValue: rawAvailability) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_capability.availability", value: rawAvailability)
        }
        let rawQuality = nullableText(statement, 5)
        let timingQuality: TrajectoryBoundaryQuality?
        if let rawQuality {
            guard let quality = TrajectoryBoundaryQuality(rawValue: rawQuality) else {
                throw UsageAnalyticsStoreError.invalidStoredValue(column: "trajectory_capability.timing_quality", value: rawQuality)
            }
            timingQuality = quality
        } else {
            timingQuality = nil
        }
        do {
            return try TrajectoryCapability.normalized(
                agent: agent,
                sessionKey: text(statement, 1),
                sourceKey: text(statement, 2),
                family: family,
                availability: availability,
                timingQuality: timingQuality,
                sourceSchemaVersion: text(statement, 6),
                importerVersion: Int(sqlite3_column_int64(statement, 7))
            )
        } catch {
            throw UsageAnalyticsStoreError.invalidStoredValue(
                column: "trajectory_capability",
                value: String(describing: error)
            )
        }
    }

    private func decodeOptional<T: RawRepresentable>(
        _: T.Type,
        statement: OpaquePointer,
        index: Int32,
        column: String
    ) throws -> T? where T.RawValue == String {
        guard let raw = nullableText(statement, index) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(column: column, value: raw)
        }
        return value
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.execute(database, "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.execute(database, "COMMIT")
        } catch {
            try? Self.execute(database, "ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw sqliteError()
    }

    private func requireDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func sqliteError() -> UsageAnalyticsStoreError {
        UsageAnalyticsStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw UsageAnalyticsStoreError.sqlite(message)
        }
    }

    private func bind(_ values: [SQLiteValue], in statement: OpaquePointer) {
        for (offset, value) in values.enumerated() { bind(value, to: Int32(offset + 1), in: statement) }
    }

    private func bind(_ value: SQLiteValue, to index: Int32, in statement: OpaquePointer) {
        switch value {
        case let .integer(value): sqlite3_bind_int64(statement, index, value)
        case let .text(value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        bind(.text(value), to: index, in: statement)
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) {
        bind(.integer(value), to: index, in: statement)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        nullableText(statement, index) ?? ""
    }

    private func nullableText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func nullableInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }
}

private enum SQLiteValue {
    case integer(Int64)
    case text(String)
    case null

    static func optionalInteger(_ value: Int64?) -> SQLiteValue { value.map(integer) ?? .null }
    static func optionalText(_ value: String?) -> SQLiteValue { value.map(text) ?? .null }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqlite3_user_version(_ database: OpaquePointer) -> Int32 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
          let statement else { return 0 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int(statement, 0)
}
