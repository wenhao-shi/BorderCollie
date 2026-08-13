import Foundation
import SQLite3

enum UsageSourceLocations {
    static func claudeProjects(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("projects")
    }

    static func codexSessions(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return root.appendingPathComponent("sessions")
    }

    static func openCodeDatabase(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dataRoot = environment["XDG_DATA_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return dataRoot.appendingPathComponent("opencode/opencode.db")
    }

    static func piSessions(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root = environment["PI_CODING_AGENT_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        return root.appendingPathComponent("sessions")
    }
}

private enum JSONLImportEngine {
    static func sources(
        agent: UsageAgent,
        root: URL,
        checkpoints: [String: UsageImportCheckpoint],
        importerVersion: Int
    ) throws -> ([PreparedJSONLSource], Set<String>) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return ([], [])
        }
        let urls = try UsageSourceDiscovery.jsonlFiles(below: root)
        let prepared = try urls.map { url in
            let key = UsageSourceIdentity.sourceKey(agent: agent, url: url)
            return try UsageSourceDiscovery.prepareJSONLSource(
                agent: agent,
                url: url,
                checkpoint: checkpoints[key],
                importerVersion: importerVersion
            )
        }
        let discovered = Set(prepared.map(\.sourceKey))
        return (prepared, Set(checkpoints.keys).subtracting(discovered))
    }

    static func checkpoint(
        agent: UsageAgent,
        source: PreparedJSONLSource,
        nextByteOffset: Int64,
        highWatermark: String?,
        importerVersion: Int
    ) -> UsageImportCheckpoint {
        UsageImportCheckpoint(
            agent: agent,
            sourceKey: source.sourceKey,
            sourceIdentity: source.metadata.identity,
            sourceSize: source.metadata.size,
            modifiedAtMilliseconds: source.metadata.modifiedAtMilliseconds,
            byteOffset: nextByteOffset,
            highWatermark: highWatermark,
            importerVersion: importerVersion
        )
    }

    static func object(from record: JSONLRecord) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: record.data) as? [String: Any] else {
            throw UsageImporterError.expectedObject
        }
        return object
    }
}

enum UsageImporterError: Error, Equatable {
    case expectedObject
    case sqliteOpen(String)
    case sqlitePrepare(String)
    case sqliteStep(String)
    case invalidUTF8
}

struct ClaudeCodeUsageImporter: UsageSourceImporter {
    let agent = UsageAgent.claudeCode
    let importerVersion = 1
    let projectsRoot: URL

    init(projectsRoot: URL = UsageSourceLocations.claudeProjects()) {
        self.projectsRoot = projectsRoot
    }

    func importBatch(checkpoints: [String: UsageImportCheckpoint]) throws -> UsageImportBatch {
        var batch = UsageImportBatch(agent: agent)
        let (sources, removed) = try JSONLImportEngine.sources(
            agent: agent,
            root: projectsRoot,
            checkpoints: checkpoints,
            importerVersion: importerVersion
        )
        batch.removedSourceKeys = removed
        var eventsByID: [String: UsageEvent] = [:]

        for source in sources {
            if source.resetRequired { batch.resetSourceKeys.insert(source.sourceKey) }
            let read = try JSONLIncrementalReader.read(url: source.url, from: source.startOffset)
            for record in read.records {
                do {
                    let object = try JSONLImportEngine.object(from: record)
                    guard let event = try parse(object: object, sourceKey: source.sourceKey, offset: record.byteOffset) else {
                        continue
                    }
                    eventsByID[event.id] = event
                } catch {
                    batch.issues.append(issue(agent: agent, sourceKey: source.sourceKey, offset: record.byteOffset, error: error))
                }
            }
            batch.checkpoints.append(JSONLImportEngine.checkpoint(
                agent: agent,
                source: source,
                nextByteOffset: read.nextByteOffset,
                highWatermark: nil,
                importerVersion: importerVersion
            ))
        }

        batch.events = Array(eventsByID.values)
        return batch
    }

    private func parse(object: [String: Any], sourceKey: String, offset: Int64) throws -> UsageEvent? {
        guard object.string("type") == "assistant",
              let message = object.dictionary("message"),
              let usage = message.dictionary("usage")
        else { return nil }

        let timestamp = try timestampMilliseconds(object: object, fallback: message)
        let rawModel = message.string("model") ?? "unknown"
        let cacheCreation = usage.dictionary("cache_creation")
        let write5m = cacheCreation?.int64("ephemeral_5m_input_tokens")
        let write1h = cacheCreation?.int64("ephemeral_1h_input_tokens")
        let cacheWrite: Int64?
        if write5m != nil || write1h != nil {
            cacheWrite = [write5m ?? 0, write1h ?? 0].checkedSum()
        } else {
            cacheWrite = usage.int64("cache_creation_input_tokens")
        }
        let details = usage.dictionary("output_tokens_details")
        let stableIdentity = message.string("id") ?? object.string("requestId")
            ?? "offset:\(offset)"
        let sourceID = UsageSourceIdentity.eventID("\(sourceKey)|\(stableIdentity)")

        return try UsageEvent.normalized(
            agent: agent,
            pricingAuthority: .anthropic,
            rawProviderID: "anthropic",
            rawModelID: rawModel,
            canonicalModelID: UsageModelCatalog.canonicalModelID(
                authority: .anthropic,
                rawModelID: rawModel,
                occurredAtMilliseconds: timestamp
            ),
            occurredAtMilliseconds: timestamp,
            inputTokens: usage.int64("input_tokens"),
            cacheWriteTokens: cacheWrite,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            cacheReadTokens: usage.int64("cache_read_input_tokens"),
            outputTokens: usage.int64("output_tokens"),
            reasoningOutputTokens: details?.int64("thinking_tokens"),
            sourceTotalTokens: nil,
            sourceKey: sourceKey,
            sourceID: sourceID,
            sourceSchemaVersion: "claude-transcript-v1",
            importerVersion: importerVersion
        )
    }
}

struct CodexUsageImporter: UsageSourceImporter {
    let agent = UsageAgent.codex
    let importerVersion = 1
    let sessionsRoot: URL

    init(sessionsRoot: URL = UsageSourceLocations.codexSessions()) {
        self.sessionsRoot = sessionsRoot
    }

    func importBatch(checkpoints: [String: UsageImportCheckpoint]) throws -> UsageImportBatch {
        var batch = UsageImportBatch(agent: agent)
        let (sources, removed) = try JSONLImportEngine.sources(
            agent: agent,
            root: sessionsRoot,
            checkpoints: checkpoints,
            importerVersion: importerVersion
        )
        batch.removedSourceKeys = removed

        for source in sources {
            if source.resetRequired { batch.resetSourceKeys.insert(source.sourceKey) }
            var currentModel = source.priorHighWatermark
            let read = try JSONLIncrementalReader.read(url: source.url, from: source.startOffset)
            for record in read.records {
                do {
                    let object = try JSONLImportEngine.object(from: record)
                    if object.string("type") == "turn_context",
                       let model = object.dictionary("payload")?.string("model") {
                        currentModel = model
                        continue
                    }
                    guard let event = try parse(
                        object: object,
                        model: currentModel,
                        sourceKey: source.sourceKey,
                        offset: record.byteOffset
                    ) else { continue }
                    batch.events.append(event)
                } catch {
                    batch.issues.append(issue(agent: agent, sourceKey: source.sourceKey, offset: record.byteOffset, error: error))
                }
            }
            batch.checkpoints.append(JSONLImportEngine.checkpoint(
                agent: agent,
                source: source,
                nextByteOffset: read.nextByteOffset,
                highWatermark: currentModel,
                importerVersion: importerVersion
            ))
        }
        return batch
    }

    private func parse(
        object: [String: Any],
        model: String?,
        sourceKey: String,
        offset: Int64
    ) throws -> UsageEvent? {
        guard object.string("type") == "event_msg",
              let payload = object.dictionary("payload"),
              payload.string("type") == "token_count",
              let info = payload.dictionary("info"),
              let usage = info.dictionary("last_token_usage")
        else { return nil }

        let inclusiveInput = usage.int64("input_tokens")
        let cacheRead = usage.int64("cached_input_tokens")
        let cacheWrite = usage.int64("cache_write_input_tokens")
        let uncachedInput: Int64?
        if let inclusiveInput, let cacheRead, let cacheWrite {
            let (withoutRead, firstOverflow) = inclusiveInput.subtractingReportingOverflow(cacheRead)
            let (value, secondOverflow) = withoutRead.subtractingReportingOverflow(cacheWrite)
            if firstOverflow || secondOverflow || value < 0 {
                throw UsageNormalizationError.negativeToken(field: "in", value: value)
            }
            uncachedInput = value
        } else {
            uncachedInput = nil
        }

        let rawModel = model ?? "unknown"
        let timestamp = try timestampMilliseconds(object: object, fallback: payload)
        let sourceID = UsageSourceIdentity.eventID("\(sourceKey)|\(offset)")
        return try UsageEvent.normalized(
            agent: agent,
            pricingAuthority: .openAI,
            rawProviderID: "openai",
            rawModelID: rawModel,
            canonicalModelID: UsageModelCatalog.canonicalModelID(
                authority: .openAI,
                rawModelID: rawModel,
                occurredAtMilliseconds: timestamp
            ),
            occurredAtMilliseconds: timestamp,
            inputTokens: uncachedInput,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            outputTokens: usage.int64("output_tokens"),
            reasoningOutputTokens: usage.int64("reasoning_output_tokens"),
            sourceTotalTokens: usage.int64("total_tokens"),
            sourceKey: sourceKey,
            sourceID: sourceID,
            sourceSchemaVersion: "codex-rollout-v1",
            importerVersion: importerVersion
        )
    }
}

struct PiUsageImporter: UsageSourceImporter {
    let agent = UsageAgent.pi
    let importerVersion = 1
    let sessionsRoot: URL

    init(sessionsRoot: URL = UsageSourceLocations.piSessions()) {
        self.sessionsRoot = sessionsRoot
    }

    func importBatch(checkpoints: [String: UsageImportCheckpoint]) throws -> UsageImportBatch {
        var batch = UsageImportBatch(agent: agent)
        let (sources, removed) = try JSONLImportEngine.sources(
            agent: agent,
            root: sessionsRoot,
            checkpoints: checkpoints,
            importerVersion: importerVersion
        )
        batch.removedSourceKeys = removed

        for source in sources {
            if source.resetRequired { batch.resetSourceKeys.insert(source.sourceKey) }
            let read = try JSONLIncrementalReader.read(url: source.url, from: source.startOffset)
            for record in read.records {
                do {
                    let object = try JSONLImportEngine.object(from: record)
                    guard let event = try parse(object: object, sourceKey: source.sourceKey, offset: record.byteOffset) else {
                        continue
                    }
                    batch.events.append(event)
                } catch {
                    batch.issues.append(issue(agent: agent, sourceKey: source.sourceKey, offset: record.byteOffset, error: error))
                }
            }
            batch.checkpoints.append(JSONLImportEngine.checkpoint(
                agent: agent,
                source: source,
                nextByteOffset: read.nextByteOffset,
                highWatermark: nil,
                importerVersion: importerVersion
            ))
        }
        return batch
    }

    private func parse(object: [String: Any], sourceKey: String, offset: Int64) throws -> UsageEvent? {
        let message = object.dictionary("message") ?? object
        guard message.string("role") == "assistant", let usage = message.dictionary("usage") else { return nil }
        let provider = message.string("provider") ?? object.string("provider")
        let rawModel = message.string("model") ?? object.string("model") ?? "unknown"
        let authority = UsageModelCatalog.authority(rawProviderID: provider)
        let timestamp = try timestampMilliseconds(object: object, fallback: message)
        let stableIdentity = message.string("responseId") ?? message.string("id")
            ?? object.string("id") ?? "offset:\(offset)"
        let sourceID = UsageSourceIdentity.eventID("\(sourceKey)|\(stableIdentity)")
        let sourceCost = usage.dictionary("cost")?.double("total") ?? usage.double("cost")

        return try UsageEvent.normalized(
            agent: agent,
            pricingAuthority: authority,
            rawProviderID: provider,
            rawModelID: rawModel,
            canonicalModelID: UsageModelCatalog.canonicalModelID(
                authority: authority,
                rawModelID: rawModel,
                occurredAtMilliseconds: timestamp
            ),
            occurredAtMilliseconds: timestamp,
            inputTokens: usage.int64("input"),
            cacheWriteTokens: usage.int64("cacheWrite"),
            cacheReadTokens: usage.int64("cacheRead"),
            outputTokens: usage.int64("output"),
            reasoningOutputTokens: usage.int64("reasoning"),
            sourceTotalTokens: usage.int64("totalTokens"),
            sourceReportedCostNanodollars: try UsageMoney.nanodollars(fromUSD: sourceCost),
            sourceKey: sourceKey,
            sourceID: sourceID,
            sourceSchemaVersion: "pi-session-v1",
            importerVersion: importerVersion
        )
    }
}

struct OpenCodeUsageImporter: UsageSourceImporter {
    let agent = UsageAgent.openCode
    let importerVersion = 1
    let databaseURL: URL

    init(databaseURL: URL = UsageSourceLocations.openCodeDatabase()) {
        self.databaseURL = databaseURL
    }

    func importBatch(checkpoints: [String: UsageImportCheckpoint]) throws -> UsageImportBatch {
        var batch = UsageImportBatch(agent: agent)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            batch.issues.append(UsageImportIssue(
                agent: agent,
                sourceKey: nil,
                severity: .warning,
                message: "OpenCode history database is unavailable; prior indexed data was preserved"
            ))
            return batch
        }

        let sourceKey = UsageSourceIdentity.sourceKey(agent: agent, url: databaseURL)
        let metadata = try UsageSourceIdentity.metadata(for: databaseURL)
        let checkpoint = checkpoints[sourceKey]
        let reset = checkpoint.map {
            $0.sourceIdentity != metadata.identity || $0.importerVersion != importerVersion
        } ?? false
        if reset { batch.resetSourceKeys.insert(sourceKey) }
        batch.removedSourceKeys = Set(checkpoints.keys).subtracting([sourceKey])
        let boundary = reset ? nil : checkpoint?.highWatermark

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            defer { if database != nil { sqlite3_close(database) } }
            throw UsageImporterError.sqliteOpen(sqliteMessage(database))
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, time_created, time_updated, data
        FROM message
        WHERE (?1 IS NULL OR time_updated >= CAST(?1 AS INTEGER))
        ORDER BY time_updated, id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageImporterError.sqlitePrepare(sqliteMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        if let boundary {
            sqlite3_bind_text(statement, 1, boundary, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 1)
        }

        var highWatermark = boundary
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw UsageImporterError.sqliteStep(sqliteMessage(database)) }
            guard let id = sqliteText(statement, 0), let dataText = sqliteText(statement, 3) else {
                batch.issues.append(UsageImportIssue(agent: agent, sourceKey: sourceKey, severity: .warning, message: "Skipped OpenCode row with invalid text fields"))
                continue
            }
            let created = sqlite3_column_int64(statement, 1)
            let updated = sqlite3_column_int64(statement, 2)
            highWatermark = String(updated)
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(dataText.utf8)) as? [String: Any],
                      object.string("role") == "assistant",
                      let tokens = object.dictionary("tokens")
                else { continue }
                let provider = object.string("providerID")
                let rawModel = object.string("modelID") ?? "unknown"
                let authority = UsageModelCatalog.authority(rawProviderID: provider)
                let cache = tokens.dictionary("cache")
                let rawOutput = tokens.int64("output")
                let reasoning = tokens.int64("reasoning")
                let normalizedOutput: Int64?
                if let rawOutput, let reasoning {
                    guard let combined = [rawOutput, reasoning].checkedSum() else {
                        throw UsageNormalizationError.arithmeticOverflow
                    }
                    normalizedOutput = combined
                } else {
                    normalizedOutput = rawOutput
                }
                let sourceID = UsageSourceIdentity.eventID(id)
                let event = try UsageEvent.normalized(
                    agent: agent,
                    pricingAuthority: authority,
                    rawProviderID: provider,
                    rawModelID: rawModel,
                    canonicalModelID: UsageModelCatalog.canonicalModelID(
                        authority: authority,
                        rawModelID: rawModel,
                        occurredAtMilliseconds: created
                    ),
                    occurredAtMilliseconds: created,
                    inputTokens: tokens.int64("input"),
                    cacheWriteTokens: cache?.int64("write"),
                    cacheReadTokens: cache?.int64("read"),
                    outputTokens: normalizedOutput,
                    reasoningOutputTokens: reasoning,
                    sourceTotalTokens: tokens.int64("total"),
                    sourceReportedCostNanodollars: try UsageMoney.nanodollars(fromUSD: object.double("cost")),
                    sourceKey: sourceKey,
                    sourceID: sourceID,
                    sourceSchemaVersion: "opencode-message-v1",
                    importerVersion: importerVersion
                )
                batch.events.append(event)
            } catch {
                batch.issues.append(UsageImportIssue(agent: agent, sourceKey: sourceKey, severity: .warning, message: "Skipped OpenCode row \(id): \(error)"))
            }
        }

        batch.checkpoints.append(UsageImportCheckpoint(
            agent: agent,
            sourceKey: sourceKey,
            sourceIdentity: metadata.identity,
            sourceSize: metadata.size,
            modifiedAtMilliseconds: metadata.modifiedAtMilliseconds,
            byteOffset: 0,
            highWatermark: highWatermark,
            importerVersion: importerVersion
        ))
        return batch
    }
}

private func timestampMilliseconds(object: [String: Any], fallback: [String: Any]) throws -> Int64 {
    if let value = object.string("timestamp") ?? fallback.string("timestamp") {
        return try UsageTimestampParser.milliseconds(from: value)
    }
    if let value = object.int64("timestamp") ?? fallback.int64("timestamp") {
        return value > 10_000_000_000 ? value : value * 1_000
    }
    if let time = object.dictionary("time"), let value = time.int64("created") ?? time.int64("completed") {
        return value > 10_000_000_000 ? value : value * 1_000
    }
    throw UsageImportSupportError.invalidTimestamp("missing")
}

private func issue(agent: UsageAgent, sourceKey: String, offset: Int64, error: Error) -> UsageImportIssue {
    UsageImportIssue(
        agent: agent,
        sourceKey: sourceKey,
        severity: .warning,
        message: "Skipped record at byte \(offset): \(error)"
    )
}

private func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
}

private func sqliteMessage(_ database: OpaquePointer?) -> String {
    guard let database, let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
    return String(cString: message)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
