import Foundation

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

private struct PendingActiveTurn: Codable, Sendable {
    let sourceID: String
    let startedAtMilliseconds: Int64
}

private struct JSONLImporterState: Codable, Sendable {
    var currentModel: String? = nil
    var pendingTurn: PendingActiveTurn? = nil
}

private enum JSONLImporterStateCodec {
    static func decode(_ value: String?) -> JSONLImporterState {
        guard let value, let data = value.data(using: .utf8),
              let state = try? JSONDecoder().decode(JSONLImporterState.self, from: data)
        else {
            return JSONLImporterState()
        }
        return state
    }

    static func encode(_ state: JSONLImporterState) -> String? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ClaudeCodeUsageImporter: UsageSourceImporter {
    let agent = UsageAgent.claudeCode
    let importerVersion = 2
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
            var state = JSONLImporterStateCodec.decode(source.priorHighWatermark)
            let read = try JSONLIncrementalReader.read(url: source.url, from: source.startOffset)
            for record in read.records {
                do {
                    let object = try JSONLImportEngine.object(from: record)
                    if let turn = try parseTiming(
                        object: object,
                        sourceKey: source.sourceKey,
                        offset: record.byteOffset,
                        state: &state
                    ) {
                        batch.activeTurns.append(turn)
                    }
                    if let event = try parse(object: object, sourceKey: source.sourceKey, offset: record.byteOffset) {
                        eventsByID[event.id] = event
                    }
                } catch {
                    batch.issues.append(issue(agent: agent, sourceKey: source.sourceKey, offset: record.byteOffset, error: error))
                }
            }
            batch.checkpoints.append(JSONLImportEngine.checkpoint(
                agent: agent,
                source: source,
                nextByteOffset: read.nextByteOffset,
                highWatermark: JSONLImporterStateCodec.encode(state),
                importerVersion: importerVersion
            ))
        }

        batch.events = Array(eventsByID.values)
        return batch
    }

    private func parseTiming(
        object: [String: Any],
        sourceKey: String,
        offset: Int64,
        state: inout JSONLImporterState
    ) throws -> UsageActiveTurn? {
        if isHumanClaudeMessage(object), state.pendingTurn == nil {
            let message = object.dictionary("message") ?? [:]
            let startedAt = try timestampMilliseconds(object: object, fallback: message)
            let identity = object.string("uuid") ?? message.string("id") ?? "offset:\(offset)"
            state.pendingTurn = PendingActiveTurn(
                sourceID: UsageSourceIdentity.eventID("\(sourceKey)|turn|\(identity)"),
                startedAtMilliseconds: startedAt
            )
            return nil
        }

        guard object.string("type") == "assistant",
              let message = object.dictionary("message"),
              let stopReason = message.string("stop_reason"),
              stopReason != "tool_use",
              let pending = state.pendingTurn
        else {
            return nil
        }

        let endedAt = try timestampMilliseconds(object: object, fallback: message)
        let rawModel = message.string("model") ?? state.currentModel ?? "unknown"
        state.pendingTurn = nil
        state.currentModel = rawModel
        return try UsageActiveTurn.normalized(
            agent: agent,
            sessionKey: sourceKey,
            pricingAuthority: .anthropic,
            rawModelID: rawModel,
            canonicalModelID: UsageModelCatalog.canonicalModelID(
                authority: .anthropic,
                rawModelID: rawModel,
                occurredAtMilliseconds: pending.startedAtMilliseconds
            ),
            startedAtMilliseconds: pending.startedAtMilliseconds,
            endedAtMilliseconds: endedAt,
            timingQuality: .inferred,
            sourceKey: sourceKey,
            sourceID: pending.sourceID,
            importerVersion: importerVersion
        )
    }

    private func isHumanClaudeMessage(_ object: [String: Any]) -> Bool {
        guard object.string("type") == "user", object.bool("isMeta") != true,
              let message = object.dictionary("message")
        else {
            return false
        }
        if message["content"] is String { return true }
        guard let content = message.array("content") else { return false }
        let humanKinds: Set<String> = ["text", "image", "document"]
        return content.contains { value in
            guard let item = value as? [String: Any], let type = item.string("type") else { return false }
            return humanKinds.contains(type)
        }
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
    let importerVersion = 2
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
            var state = JSONLImporterStateCodec.decode(source.priorHighWatermark)
            let read = try JSONLIncrementalReader.read(url: source.url, from: source.startOffset)
            for record in read.records {
                do {
                    let object = try JSONLImportEngine.object(from: record)
                    if object.string("type") == "turn_context",
                       let model = object.dictionary("payload")?.string("model") {
                        state.currentModel = model
                        continue
                    }
                    if let turn = try parseTiming(
                        object: object,
                        sourceKey: source.sourceKey,
                        offset: record.byteOffset,
                        state: &state
                    ) {
                        batch.activeTurns.append(turn)
                    }
                    guard let event = try parse(
                        object: object,
                        model: state.currentModel,
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
                highWatermark: JSONLImporterStateCodec.encode(state),
                importerVersion: importerVersion
            ))
        }
        return batch
    }

    private func parseTiming(
        object: [String: Any],
        sourceKey: String,
        offset: Int64,
        state: inout JSONLImporterState
    ) throws -> UsageActiveTurn? {
        guard object.string("type") == "event_msg",
              let payload = object.dictionary("payload"),
              let type = payload.string("type")
        else {
            return nil
        }

        if type == "task_started" {
            state.pendingTurn = PendingActiveTurn(
                sourceID: UsageSourceIdentity.eventID("\(sourceKey)|turn|\(offset)"),
                startedAtMilliseconds: try timestampMilliseconds(object: object, fallback: payload)
            )
            return nil
        }

        guard type == "task_complete", let pending = state.pendingTurn else {
            return nil
        }
        let endedAt = try timestampMilliseconds(object: object, fallback: payload)
        let rawModel = state.currentModel ?? "unknown"
        state.pendingTurn = nil
        return try UsageActiveTurn.normalized(
            agent: agent,
            sessionKey: sourceKey,
            pricingAuthority: .openAI,
            rawModelID: rawModel,
            canonicalModelID: UsageModelCatalog.canonicalModelID(
                authority: .openAI,
                rawModelID: rawModel,
                occurredAtMilliseconds: pending.startedAtMilliseconds
            ),
            startedAtMilliseconds: pending.startedAtMilliseconds,
            endedAtMilliseconds: endedAt,
            timingQuality: .exact,
            sourceKey: sourceKey,
            sourceID: pending.sourceID,
            importerVersion: importerVersion
        )
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

private func timestampMilliseconds(object: [String: Any], fallback: [String: Any]) throws -> Int64 {
    if let value = object.string("timestamp") ?? fallback.string("timestamp") {
        return try UsageTimestampParser.milliseconds(from: value)
    }
    if let value = object.int64("timestamp") ?? fallback.int64("timestamp") {
        return normalizedEpochMilliseconds(value)
    }
    if let time = object.dictionary("time"), let value = time.int64("created") ?? time.int64("completed") {
        return normalizedEpochMilliseconds(value)
    }
    throw UsageImportSupportError.invalidTimestamp("missing")
}

private func normalizedEpochMilliseconds(_ value: Int64) -> Int64 {
    value > 10_000_000_000 ? value : value * 1_000
}

private func issue(agent: UsageAgent, sourceKey: String, offset: Int64, error: Error) -> UsageImportIssue {
    UsageImportIssue(
        agent: agent,
        sourceKey: sourceKey,
        severity: .warning,
        message: "Skipped record at byte \(offset): \(error)"
    )
}
