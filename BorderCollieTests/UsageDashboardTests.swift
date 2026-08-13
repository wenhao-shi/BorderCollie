import Foundation
import SQLite3
import Testing
@testable import BorderCollie

struct UsageDashboardTests {
    @Test func canonicalNormalizationKeepsReasoningInsideOutput() throws {
        let event = try makeEvent(input: 10, cacheWrite: 20, cacheRead: 30, output: 40, reasoning: 25)

        #expect(event.completeness == .complete)
        #expect(event.totalTokens == 100)
        #expect(event.reasoningOutputTokens == 25)
        #expect(throws: UsageNormalizationError.self) {
            try makeEvent(input: 1, cacheWrite: 0, cacheRead: 0, output: 2, reasoning: 3)
        }
    }

    @Test func missingBucketAndMismatchedSourceTotalRemainPartial() throws {
        let missing = try UsageEvent.normalized(
            agent: .pi, pricingAuthority: .openAI, rawProviderID: "openai-codex",
            rawModelID: "gpt-5.6-sol", canonicalModelID: "gpt-5.6-sol",
            occurredAtMilliseconds: timestamp("2026-08-01T12:00:00Z"), inputTokens: 1,
            cacheWriteTokens: nil, cacheReadTokens: 2, outputTokens: 3, sourceTotalTokens: nil,
            sourceKey: "source", sourceID: "missing", sourceSchemaVersion: "test", importerVersion: 1
        )
        let mismatch = try UsageEvent.normalized(
            agent: .pi, pricingAuthority: .openAI, rawProviderID: "openai-codex",
            rawModelID: "gpt-5.6-sol", canonicalModelID: "gpt-5.6-sol",
            occurredAtMilliseconds: timestamp("2026-08-01T12:00:00Z"), inputTokens: 1,
            cacheWriteTokens: 2, cacheReadTokens: 3, outputTokens: 4, sourceTotalTokens: 11,
            sourceKey: "source", sourceID: "mismatch", sourceSchemaVersion: "test", importerVersion: 1
        )

        #expect(missing.completeness == .partial)
        #expect(missing.totalTokens == nil)
        #expect(mismatch.completeness == .partial)
        #expect(mismatch.totalTokens == 10)
    }

    @Test func claudeImporterDeduplicatesAndRefreshesAppendOnly() throws {
        let fixture = try TemporaryUsageFixture()
        let file = try fixture.file("project/session.jsonl", contents: claudeLine(id: "message-1") + "\n" + claudeLine(id: "message-1") + "\n{bad json}\n")
        let importer = ClaudeCodeUsageImporter(projectsRoot: fixture.root)

        let first = try importer.importBatch(checkpoints: [:])
        let event = try #require(first.events.first)
        #expect(first.events.count == 1)
        #expect(first.issues.count == 1)
        #expect(event.inputTokens == 100)
        #expect(event.cacheWriteTokens == 30)
        #expect(event.cacheWrite5mTokens == 20)
        #expect(event.cacheWrite1hTokens == 10)
        #expect(event.cacheReadTokens == 40)
        #expect(event.outputTokens == 50)
        #expect(event.reasoningOutputTokens == 25)
        #expect(event.totalTokens == 220)

        try append(claudeLine(id: "message-2") + "\n", to: file)
        let checkpoint = try #require(first.checkpoints.first)
        let second = try importer.importBatch(checkpoints: [checkpoint.sourceKey: checkpoint])
        #expect(second.events.count == 1)
        #expect(second.resetSourceKeys.isEmpty)
    }

    @Test func codexImporterUsesLastRequestUsageAndCurrentModel() throws {
        let fixture = try TemporaryUsageFixture()
        _ = try fixture.file("2026/08/01/rollout.jsonl", contents: #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"# + "\n" + #"{"timestamp":"2026-08-01T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9999},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":12,"total_tokens":130}}}}"# + "\n")
        let batch = try CodexUsageImporter(sessionsRoot: fixture.root).importBatch(checkpoints: [:])
        let event = try #require(batch.events.first)

        #expect(batch.events.count == 1)
        #expect(event.rawModelID == "gpt-5.6-terra")
        #expect(event.inputTokens == 70)
        #expect(event.cacheWriteTokens == 10)
        #expect(event.cacheReadTokens == 20)
        #expect(event.outputTokens == 30)
        #expect(event.totalTokens == 130)
    }

    @Test func piImporterPreservesProviderModelAndReportedCost() throws {
        let fixture = try TemporaryUsageFixture()
        _ = try fixture.file("session/session.jsonl", contents: #"{"id":"entry-1","timestamp":"2026-08-01T12:00:00Z","type":"message","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","responseId":"response-1","usage":{"input":10,"cacheWrite":20,"cacheRead":30,"output":40,"reasoning":10,"totalTokens":100,"cost":{"input":0.1,"cacheWrite":0.1,"cacheRead":0.1,"output":0.1,"total":0.4}}}}"# + "\n")
        let batch = try PiUsageImporter(sessionsRoot: fixture.root).importBatch(checkpoints: [:])
        let event = try #require(batch.events.first)

        #expect(event.pricingAuthority == .openAI)
        #expect(event.rawProviderID == "openai-codex")
        #expect(event.canonicalModelID == "gpt-5.6-sol")
        #expect(event.totalTokens == 100)
        #expect(event.sourceReportedCostNanodollars == 400_000_000)
    }

    @Test func openCodeImporterReadsSourceDatabaseWithoutWritingIt() throws {
        let fixture = try TemporaryUsageFixture()
        let databaseURL = fixture.root.appendingPathComponent("opencode.db")
        try createOpenCodeDatabase(at: databaseURL)
        let before = try UsageSourceIdentity.metadata(for: databaseURL)

        let first = try OpenCodeUsageImporter(databaseURL: databaseURL).importBatch(checkpoints: [:])
        let event = try #require(first.events.first)
        let after = try UsageSourceIdentity.metadata(for: databaseURL)
        #expect(event.rawProviderID == "opencode")
        #expect(event.rawModelID == "free-model")
        #expect(event.pricingAuthority == .unknown)
        #expect(event.sourceReportedCostNanodollars == 0)
        #expect(event.totalTokens == 110)
        #expect(before == after)

        let checkpoint = try #require(first.checkpoints.first)
        let second = try OpenCodeUsageImporter(databaseURL: databaseURL).importBatch(
            checkpoints: [checkpoint.sourceKey: checkpoint]
        )
        #expect(second.events.count == 1)
    }

    @Test func JSONLReaderDoesNotCheckpointAnIncompleteTrailingRecord() throws {
        let fixture = try TemporaryUsageFixture()
        let file = try fixture.file("partial.jsonl", contents: "{\"one\":1}\n{\"two\":")
        let first = try JSONLIncrementalReader.read(url: file, from: 0)
        #expect(first.records.count == 1)
        #expect(first.nextByteOffset == 10)

        try append("2}\n", to: file)
        let second = try JSONLIncrementalReader.read(url: file, from: first.nextByteOffset)
        #expect(second.records.count == 1)
    }

    @Test func JSONLSourceResetDetectsTruncationAndImporterVersionChanges() throws {
        let fixture = try TemporaryUsageFixture()
        let file = try fixture.file("source.jsonl", contents: "{\"one\":1}\n")
        let sourceKey = UsageSourceIdentity.sourceKey(agent: .pi, url: file)
        let metadata = try UsageSourceIdentity.metadata(for: file)
        let checkpoint = UsageImportCheckpoint(
            agent: .pi, sourceKey: sourceKey, sourceIdentity: metadata.identity,
            sourceSize: metadata.size + 10, modifiedAtMilliseconds: metadata.modifiedAtMilliseconds,
            byteOffset: metadata.size + 10, highWatermark: nil, importerVersion: 1
        )

        let truncated = try UsageSourceDiscovery.prepareJSONLSource(
            agent: .pi, url: file, checkpoint: checkpoint, importerVersion: 1
        )
        let upgraded = try UsageSourceDiscovery.prepareJSONLSource(
            agent: .pi,
            url: file,
            checkpoint: UsageImportCheckpoint(
                agent: .pi, sourceKey: sourceKey, sourceIdentity: metadata.identity,
                sourceSize: metadata.size, modifiedAtMilliseconds: metadata.modifiedAtMilliseconds,
                byteOffset: metadata.size, highWatermark: nil, importerVersion: 1
            ),
            importerVersion: 2
        )

        #expect(truncated.resetRequired)
        #expect(truncated.startOffset == 0)
        #expect(upgraded.resetRequired)
    }

    @Test func normalizationRejectsNegativeAndOverflowingTokens() {
        #expect(throws: UsageNormalizationError.self) {
            try makeEvent(input: -1)
        }
        #expect(throws: UsageNormalizationError.self) {
            try makeEvent(input: Int64.max, output: 1)
        }
    }

    @Test func storeCreatesSchemaUpsertsIdempotentlyAndRollsBackBatch() async throws {
        let fixture = try TemporaryUsageFixture()
        let store = try UsageAnalyticsStore(databaseURL: fixture.root.appendingPathComponent("analytics.sqlite3"))
        var batch = UsageImportBatch(agent: .pi)
        batch.events = [try makeEvent()]
        batch.checkpoints = [checkpoint(sourceKey: "source")]
        try await store.apply(batch)
        try await store.apply(batch)
        #expect(try await store.eventCount() == 1)
        #expect(try await store.events(agents: []).isEmpty)

        let rollbackStore = try UsageAnalyticsStore(databaseURL: fixture.root.appendingPathComponent("rollback.sqlite3"))
        var invalid = UsageImportBatch(agent: .pi)
        invalid.events = [try makeEvent(sourceID: "rollback")]
        invalid.checkpoints = [checkpoint(sourceKey: "")]
        await #expect(throws: UsageAnalyticsStoreError.self) {
            try await rollbackStore.apply(invalid)
        }
        #expect(try await rollbackStore.eventCount() == 0)
    }

    @Test func storeMigratesVersionOneAliasSchema() async throws {
        let fixture = try TemporaryUsageFixture()
        let url = fixture.root.appendingPathComponent("legacy.sqlite3")
        try createLegacyVersionOneDatabase(at: url)

        let store = try UsageAnalyticsStore(databaseURL: url)
        _ = store
        #expect(try databaseUserVersion(at: url) == UsageAnalyticsStore.schemaVersion)
        #expect(try databaseColumns(table: "model_alias", at: url) == [
            "authority", "raw_model_id", "canonical_model_id", "effective_from_ms",
            "effective_until_ms", "source_url",
        ])
    }

    @Test func pricingUsesEffectiveRuleCacheClassesAndLongContextModifier() throws {
        var claude = try makeEvent(
            agent: .claudeCode, authority: .anthropic, model: "claude-sonnet-5",
            occurredAt: "2026-08-01T12:00:00Z", input: 100, cacheWrite: 20,
            cacheRead: 30, output: 40, reasoning: 10, write5m: 10, write1h: 10
        )
        let engine = UsagePricingEngine()
        #expect(engine.price(claude) == .priced(costNanodollars: 671_000, ruleID: "anthropic-sonnet-5-intro"))

        claude = try makeEvent(
            agent: .claudeCode, authority: .anthropic, model: "claude-sonnet-5",
            occurredAt: "2026-09-01T00:00:00Z", input: 100, cacheWrite: 0,
            cacheRead: 0, output: 100
        )
        #expect(engine.price(claude) == .priced(costNanodollars: 1_800_000, ruleID: "anthropic-sonnet-5-standard"))

        let long = try makeEvent(input: 273_000, cacheWrite: 0, cacheRead: 0, output: 1_000)
        #expect(engine.price(long) == .priced(costNanodollars: 2_775_000_000, ruleID: "openai-gpt-5.6-sol"))
    }

    @Test func aggregationReconcilesBucketsRatesCoverageAndFilters() throws {
        var priced = try makeEvent(input: 10, cacheWrite: 20, cacheRead: 30, output: 40, reasoning: 5)
        priced.estimatedAPICostNanodollars = 1_000
        priced.pricingRuleID = "rule"
        let unpriced = try makeEvent(agent: .codex, sourceID: "unpriced", input: 1, cacheWrite: 2, cacheRead: 3, output: 4)
        let partial = try UsageEvent.normalized(
            agent: .pi, pricingAuthority: .openAI, rawProviderID: "openai-codex", rawModelID: "unknown",
            canonicalModelID: nil, occurredAtMilliseconds: timestamp("2026-08-01T12:00:00Z"),
            inputTokens: 1, cacheWriteTokens: nil, cacheReadTokens: 1, outputTokens: 1,
            sourceTotalTokens: nil, sourceKey: "source", sourceID: "partial",
            sourceSchemaVersion: "test", importerVersion: 1
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(timestamp("2026-08-01T00:00:00Z")) / 1_000),
            end: Date(timeIntervalSince1970: TimeInterval(timestamp("2026-08-02T00:00:00Z")) / 1_000)
        )
        let aggregate = try UsageAggregator().aggregate(
            events: [priced, unpriced, partial], range: .oneDay, interval: interval,
            agents: Set(UsageAgent.allCases), calendar: utcCalendar
        )

        #expect(aggregate.inputTokens == 11)
        #expect(aggregate.cacheWriteTokens == 22)
        #expect(aggregate.cacheReadTokens == 33)
        #expect(aggregate.outputTokens == 44)
        #expect(aggregate.totalTokens == 110)
        #expect(aggregate.estimatedCostNanodollars == 1_000)
        #expect(aggregate.inputCacheHitRate == 0.5)
        #expect(aggregate.outputShare == 0.4)
        #expect(aggregate.coverage == UsageCoverage(totalEvents: 3, completeEvents: 2, pricedEvents: 1, partialEvents: 1, unpricedCompleteEvents: 1))
        #expect(aggregate.daily.count == UsageAgent.allCases.count)
        #expect(aggregate.chartPoints.count == UsageAgent.allCases.count * 24)

        let pricedPoint = try #require(aggregate.daily.first { $0.agent == .pi })
        let unpricedPoint = try #require(aggregate.daily.first { $0.agent == .codex })
        #expect(pricedPoint.completeEvents == 1)
        #expect(pricedPoint.pricedEvents == 1)
        #expect(pricedPoint.inputTokens == 10)
        #expect(pricedPoint.cacheWriteTokens == 20)
        #expect(pricedPoint.cacheReadTokens == 30)
        #expect(pricedPoint.outputTokens == 40)
        #expect(unpricedPoint.completeEvents == 1)
        #expect(unpricedPoint.pricedEvents == 0)

        let pricedModel = try #require(aggregate.models.first { $0.agent == .pi })
        #expect(pricedModel.inputTokens == 10)
        #expect(pricedModel.cacheWriteTokens == 20)
        #expect(pricedModel.cacheReadTokens == 30)
        #expect(pricedModel.outputTokens == 40)
        #expect(pricedModel.reasoningOutputTokens == 5)

        let summaries = UsageDashboardPresentation.agentSummaries(from: aggregate)
        #expect(summaries.map(\.agent) == [.codex, .pi])
        #expect(summaries.first { $0.agent == .codex }?.hasPartialPricing == true)
        #expect(UsageDashboardPresentation.chartAgents(from: aggregate, metric: .cost) == [.pi])
        #expect(UsageDashboardPresentation.chartAgents(from: aggregate, metric: .tokens) == [.codex, .pi])
        let day = try #require(UsageDashboardPresentation.dayBreakdown(from: aggregate).first)
        #expect(day.completeEvents == 2)
        #expect(day.inputTokens == 11)
        #expect(day.cacheWriteTokens == 22)
        #expect(day.cacheReadTokens == 33)
        #expect(day.outputTokens == 44)
        #expect(day.inputCacheHitRate == 0.5)
        #expect(day.outputShare == 0.4)
    }

    @Test func dateRangeUsesLocalCalendarAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let end = Date(timeIntervalSince1970: TimeInterval(timestamp("2026-03-10T19:00:00Z")) / 1_000)
        let interval = try UsageDateIntervals.interval(range: .sevenDays, endingAt: end, calendar: calendar)

        #expect(calendar.component(.hour, from: interval.start) == 0)
        #expect(calendar.component(.hour, from: interval.end) == 0)
        #expect(calendar.dateComponents([.day], from: interval.start, to: interval.end).day == 7)
        #expect(interval.duration == 7 * 86_400 - 3_600)
    }

    @Test func dashboardOffersOneSevenAndThirtyDayRanges() throws {
        #expect(UsageDateRange.allCases.map(\.rawValue) == [1, 7, 30])

        let end = Date(timeIntervalSince1970: TimeInterval(timestamp("2026-08-01T12:00:00Z")) / 1_000)
        let oneDay = try UsageDateIntervals.interval(range: .oneDay, endingAt: end, calendar: utcCalendar)
        let thirtyDays = try UsageDateIntervals.interval(range: .thirtyDays, endingAt: end, calendar: utcCalendar)

        #expect(oneDay.duration == 86_400)
        #expect(oneDay.end == end)
        #expect(oneDay.start == end.addingTimeInterval(-86_400))
        #expect(UsageDateRange.oneDay.shortLabel == "24h")
        #expect(thirtyDays.duration == 30 * 86_400)
    }

    @Test func rollingTwentyFourHoursUsesHourlyChartBucketsButCalendarDayBreakdown() throws {
        let end = Date(timeIntervalSince1970: TimeInterval(timestamp("2026-08-02T12:30:00Z")) / 1_000)
        let interval = try UsageDateIntervals.interval(range: .oneDay, endingAt: end, calendar: utcCalendar)
        let events = [
            try makeEvent(sourceID: "outside-start", occurredAt: "2026-08-01T12:15:00Z"),
            try makeEvent(sourceID: "inside-first", occurredAt: "2026-08-01T12:45:00Z"),
            try makeEvent(sourceID: "inside-last", occurredAt: "2026-08-02T12:15:00Z"),
            try makeEvent(sourceID: "outside-end", occurredAt: "2026-08-02T12:30:00Z"),
        ]

        let aggregate = try UsageAggregator().aggregate(
            events: events,
            range: .oneDay,
            interval: interval,
            agents: [.pi],
            calendar: utcCalendar
        )

        #expect(aggregate.totalTokens == 40)
        #expect(aggregate.chartPoints.count == 25)
        #expect(aggregate.chartPoints.first?.timestamp == interval.start)
        #expect(aggregate.chartPoints.last?.timestamp == Date(
            timeIntervalSince1970: TimeInterval(timestamp("2026-08-02T12:00:00Z")) / 1_000
        ))
        #expect(aggregate.chartPoints.filter { $0.totalTokens > 0 }.count == 2)

        let days = UsageDashboardPresentation.dayBreakdown(from: aggregate)
        #expect(days.count == 2)
        #expect(days.allSatisfy { $0.totalTokens == 20 })
    }

    @Test func chartHoverSelectsOnlyTheNearestVisibleSegmentWithinItsHitRadius() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let series = [
            UsageChartScreenSeries(
                agent: .codex,
                points: [
                    UsageChartScreenPoint(date: start, value: 10, position: CGPoint(x: 0, y: 10)),
                    UsageChartScreenPoint(date: end, value: 30, position: CGPoint(x: 100, y: 30)),
                ]
            ),
            UsageChartScreenSeries(
                agent: .claudeCode,
                points: [
                    UsageChartScreenPoint(date: start, value: 50, position: CGPoint(x: 0, y: 50)),
                    UsageChartScreenPoint(date: end, value: 50, position: CGPoint(x: 100, y: 50)),
                ]
            ),
        ]

        let selection = try #require(
            UsageChartInteraction.nearestSelection(
                to: CGPoint(x: 50, y: 21),
                series: series,
                maximumDistance: 14
            )
        )
        #expect(selection.agent == .codex)
        #expect(abs(selection.date.timeIntervalSince(start) - 50.19) < 0.1)
        #expect(abs(selection.value - 20.04) < 0.1)

        #expect(
            UsageChartInteraction.nearestSelection(
                to: CGPoint(x: 50, y: 80),
                series: series,
                maximumDistance: 14
            ) == nil
        )
    }

    @Test func chartHoverSupportsSinglePointSeries() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let series = [
            UsageChartScreenSeries(
                agent: .pi,
                points: [UsageChartScreenPoint(date: date, value: 42, position: CGPoint(x: 20, y: 30))]
            )
        ]

        let selection = try #require(
            UsageChartInteraction.nearestSelection(
                to: CGPoint(x: 23, y: 34),
                series: series,
                maximumDistance: 5
            )
        )
        #expect(selection == UsageChartHoverSelection(agent: .pi, date: date, value: 42))
    }
}

private func makeEvent(
    agent: UsageAgent = .pi,
    authority: PricingAuthority = .openAI,
    model: String = "gpt-5.6-sol",
    sourceID: String = "event",
    occurredAt: String = "2026-08-01T12:00:00Z",
    input: Int64 = 10,
    cacheWrite: Int64 = 0,
    cacheRead: Int64 = 0,
    output: Int64 = 10,
    reasoning: Int64? = nil,
    write5m: Int64? = nil,
    write1h: Int64? = nil
) throws -> UsageEvent {
    try UsageEvent.normalized(
        agent: agent, pricingAuthority: authority, rawProviderID: authority.rawValue,
        rawModelID: model, canonicalModelID: model, occurredAtMilliseconds: timestamp(occurredAt),
        inputTokens: input, cacheWriteTokens: cacheWrite, cacheWrite5mTokens: write5m,
        cacheWrite1hTokens: write1h, cacheReadTokens: cacheRead, outputTokens: output,
        reasoningOutputTokens: reasoning, sourceTotalTokens: [input, cacheWrite, cacheRead, output].checkedSum(),
        sourceKey: "source", sourceID: sourceID, sourceSchemaVersion: "test", importerVersion: 1
    )
}

private func checkpoint(sourceKey: String) -> UsageImportCheckpoint {
    UsageImportCheckpoint(
        agent: .pi, sourceKey: sourceKey, sourceIdentity: "identity", sourceSize: 1,
        modifiedAtMilliseconds: 1, byteOffset: 1, highWatermark: nil, importerVersion: 1
    )
}

private func timestamp(_ value: String) -> Int64 {
    try! UsageTimestampParser.milliseconds(from: value)
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func claudeLine(id: String) -> String {
    #"{"type":"assistant","timestamp":"2026-08-01T12:00:00Z","requestId":"request-1","message":{"id":"\#(id)","model":"claude-sonnet-5","usage":{"input_tokens":100,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"output_tokens_details":{"thinking_tokens":25}}}}"#
}

private final class TemporaryUsageFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BorderCollieUsageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ relativePath: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private func append(_ value: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(value.utf8))
}

private func createOpenCodeDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw UsageImporterError.sqliteOpen("fixture")
    }
    defer { sqlite3_close(database) }
    let data = #"{"role":"assistant","providerID":"opencode","modelID":"free-model","cost":0,"tokens":{"total":110,"input":10,"output":40,"reasoning":10,"cache":{"read":30,"write":20}},"time":{"created":1785585600000}}"#
    guard sqlite3_exec(database, "CREATE TABLE message (id TEXT PRIMARY KEY, time_created INTEGER, time_updated INTEGER, data TEXT)", nil, nil, nil) == SQLITE_OK else {
        throw UsageImporterError.sqliteStep("fixture schema")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO message VALUES (?1, ?2, ?3, ?4)", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw UsageImporterError.sqlitePrepare("fixture insert") }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, "message-1", -1, testSQLiteTransient)
    sqlite3_bind_int64(statement, 2, timestamp("2026-08-01T12:00:00Z"))
    sqlite3_bind_int64(statement, 3, timestamp("2026-08-01T12:00:01Z"))
    sqlite3_bind_text(statement, 4, data, -1, testSQLiteTransient)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageImporterError.sqliteStep("fixture insert") }
}

private func createLegacyVersionOneDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw UsageImporterError.sqliteOpen("legacy fixture")
    }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE usage_event (completeness TEXT NOT NULL, occurred_at_ms INTEGER NOT NULL);
    CREATE TABLE model_alias (
        authority TEXT NOT NULL,
        raw_model_id TEXT NOT NULL,
        canonical_model_id TEXT NOT NULL,
        PRIMARY KEY(authority, raw_model_id)
    );
    PRAGMA user_version = 1;
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw UsageImporterError.sqliteStep("legacy fixture")
    }
}

private func databaseUserVersion(at url: URL) throws -> Int {
    try databaseScalar(at: url, sql: "PRAGMA user_version")
}

private func databaseColumns(table: String, at url: URL) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        throw UsageImporterError.sqliteOpen("column fixture")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw UsageImporterError.sqlitePrepare("column fixture") }
    defer { sqlite3_finalize(statement) }
    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        columns.append(String(cString: sqlite3_column_text(statement, 1)))
    }
    return columns
}

private func databaseScalar(at url: URL, sql: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        throw UsageImporterError.sqliteOpen("scalar fixture")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw UsageImporterError.sqlitePrepare("scalar fixture")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageImporterError.sqliteStep("scalar fixture") }
    return Int(sqlite3_column_int64(statement, 0))
}

private let testSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
