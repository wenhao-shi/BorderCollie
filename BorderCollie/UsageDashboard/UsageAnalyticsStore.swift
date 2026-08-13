import Foundation
import SQLite3

enum UsageAnalyticsStoreError: Error, Equatable {
    case sqlite(String)
    case invalidDatabasePath
    case invalidStoredValue(column: String, value: String)
    case batchAgentMismatch
}

actor UsageAnalyticsStore {
    static let schemaVersion = 2

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
              batch.checkpoints.allSatisfy({ $0.agent == batch.agent })
        else { throw UsageAnalyticsStoreError.batchAgentMismatch }

        try transaction {
            for sourceKey in batch.resetSourceKeys.union(batch.removedSourceKeys) {
                try deleteEvents(agent: batch.agent, sourceKey: sourceKey)
                try deleteCheckpoint(agent: batch.agent, sourceKey: sourceKey)
            }
            for event in batch.events { try upsert(event) }
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

    func events(interval: DateInterval? = nil, agents: Set<UsageAgent>? = nil) throws -> [UsageEvent] {
        if let agents, agents.isEmpty {
            return []
        }
        var clauses: [String] = []
        if interval != nil { clauses.append("occurred_at_ms >= ? AND occurred_at_ms < ?") }
        if let agents, !agents.isEmpty {
            clauses.append("agent IN (\(Array(repeating: "?", count: agents.count).joined(separator: ",")))")
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

        var events: [UsageEvent] = []
        while try step(statement) { events.append(try decodeEvent(statement)) }
        return events
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
           source_key, source_id, source_schema_version, importer_version
    FROM usage_event
    """

    private static func migrate(_ database: OpaquePointer) throws {
        let version = Int(sqlite3_user_version(database))
        guard version <= schemaVersion else {
            throw UsageAnalyticsStoreError.sqlite("Database schema is newer than this app")
        }
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
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_time_agent ON usage_event(occurred_at_ms, agent)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_model_time ON usage_event(canonical_model_id, occurred_at_ms)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_source ON usage_event(agent, source_key)")
            try execute(database, "CREATE INDEX IF NOT EXISTS usage_event_completeness_time ON usage_event(completeness, occurred_at_ms)")
            try execute(database, "PRAGMA user_version = 2")
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
        }
    }

    private func upsert(_ event: UsageEvent) throws {
        let sql = """
        INSERT INTO usage_event VALUES (
            ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25
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
            source_key=excluded.source_key, source_schema_version=excluded.source_schema_version,
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
            .optionalText(event.incompleteReason), .text(event.sourceKey), .text(event.sourceID),
            .text(event.sourceSchemaVersion), .integer(Int64(event.importerVersion)),
        ]
        bind(values, in: statement)
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
            sourceID: text(statement, 22), sourceSchemaVersion: text(statement, 23),
            importerVersion: Int(sqlite3_column_int64(statement, 24))
        )
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
