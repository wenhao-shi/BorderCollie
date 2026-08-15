import Foundation

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

enum TrajectoryNormalizationError: Error, Equatable, Sendable {
    case emptyField(String)
    case negativeSourceOrder(Int64)
    case nonPositiveImporterVersion(Int)
    case invalidInterval(start: Int64, end: Int64)
    case invalidFirstOutput
    case invalidStatus
    case invalidBoundaryQuality
    case selfParent
    case invalidFieldForKind(String)
    case invalidAttempt(Int)
    case invalidIdentifier
}

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
    ) throws -> TrajectoryActivity {
        for (name, value) in [
            ("sessionKey", sessionKey),
            ("sourceKey", sourceKey),
            ("sourceID", sourceID),
            ("sourceSchemaVersion", sourceSchemaVersion),
        ] where value.isEmpty {
            throw TrajectoryNormalizationError.emptyField(name)
        }
        guard sourceOrder >= 0 else {
            throw TrajectoryNormalizationError.negativeSourceOrder(sourceOrder)
        }
        guard importerVersion > 0 else {
            throw TrajectoryNormalizationError.nonPositiveImporterVersion(importerVersion)
        }
        if let endedAtMilliseconds, endedAtMilliseconds < startedAtMilliseconds {
            throw TrajectoryNormalizationError.invalidInterval(
                start: startedAtMilliseconds,
                end: endedAtMilliseconds
            )
        }
        if let firstOutputAtMilliseconds {
            guard firstOutputAtMilliseconds >= startedAtMilliseconds,
                  endedAtMilliseconds.map({ firstOutputAtMilliseconds <= $0 }) ?? true
            else { throw TrajectoryNormalizationError.invalidFirstOutput }
        }
        guard (firstOutputAtMilliseconds == nil) == (firstOutputQuality == nil) else {
            throw TrajectoryNormalizationError.invalidBoundaryQuality
        }
        guard parentActivityID != "\(agent.rawValue):\(sourceID)" else {
            throw TrajectoryNormalizationError.selfParent
        }

        let isPoint = endedAtMilliseconds == startedAtMilliseconds && endedAtMilliseconds != nil
        if status == .observed {
            guard isPoint else { throw TrajectoryNormalizationError.invalidStatus }
        } else if status == .open {
            guard endedAtMilliseconds == nil, endQuality == nil else {
                throw TrajectoryNormalizationError.invalidStatus
            }
        } else {
            guard endedAtMilliseconds != nil, endQuality != nil else {
                throw TrajectoryNormalizationError.invalidStatus
            }
        }
        if endedAtMilliseconds == nil, endQuality != nil {
            throw TrajectoryNormalizationError.invalidBoundaryQuality
        }
        if let parentActivityID, parentActivityID.isEmpty {
            throw TrajectoryNormalizationError.invalidIdentifier
        }
        if let turnID, turnID.isEmpty { throw TrajectoryNormalizationError.invalidIdentifier }

        if kind == .modelRequest {
            guard toolName == nil else { throw TrajectoryNormalizationError.invalidFieldForKind("toolName") }
        } else {
            guard rawModelID == nil else { throw TrajectoryNormalizationError.invalidFieldForKind("rawModelID") }
        }

        let sanitizedToolName = TrajectoryMetadataSanitizer.toolName(toolName)
        if kind != .tool && kind != .subtool, sanitizedToolName != nil {
            throw TrajectoryNormalizationError.invalidFieldForKind("toolName")
        }
        if let attempt, attempt <= 0 {
            throw TrajectoryNormalizationError.invalidAttempt(attempt)
        }
        if kind != .retry, attempt != nil {
            throw TrajectoryNormalizationError.invalidFieldForKind("attempt")
        }

        let id = "\(agent.rawValue):\(sourceID)"
        return TrajectoryActivity(
            id: id,
            agent: agent,
            sessionKey: sessionKey,
            turnID: turnID,
            parentActivityID: parentActivityID,
            kind: kind,
            status: status,
            sourceOrder: sourceOrder,
            orderQuality: orderQuality,
            startedAtMilliseconds: startedAtMilliseconds,
            endedAtMilliseconds: endedAtMilliseconds,
            firstOutputAtMilliseconds: firstOutputAtMilliseconds,
            startQuality: startQuality,
            endQuality: endQuality,
            firstOutputQuality: firstOutputQuality,
            rawModelID: rawModelID,
            toolName: sanitizedToolName,
            attempt: attempt,
            failureCategory: failureCategory,
            usageEventID: usageEventID,
            sourceKey: sourceKey,
            sourceID: sourceID,
            sourceSchemaVersion: sourceSchemaVersion,
            importerVersion: importerVersion
        )
    }
}

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
    ) throws -> TrajectoryCapability {
        for (name, value) in [
            ("sessionKey", sessionKey),
            ("sourceKey", sourceKey),
            ("sourceSchemaVersion", sourceSchemaVersion),
        ] where value.isEmpty {
            throw TrajectoryNormalizationError.emptyField(name)
        }
        guard importerVersion > 0 else {
            throw TrajectoryNormalizationError.nonPositiveImporterVersion(importerVersion)
        }
        guard availability != .unavailable || timingQuality == nil else {
            throw TrajectoryNormalizationError.invalidBoundaryQuality
        }
        return TrajectoryCapability(
            agent: agent,
            sessionKey: sessionKey,
            sourceKey: sourceKey,
            family: family,
            availability: availability,
            timingQuality: timingQuality,
            sourceSchemaVersion: sourceSchemaVersion,
            importerVersion: importerVersion
        )
    }
}

enum TrajectoryMetadataSanitizer {
    static func toolName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let filtered = String(rawValue.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filtered.isEmpty else { return nil }
        return String(filtered.unicodeScalars.prefix(128))
    }
}

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

extension TrajectoryPeriod {
    func interval(endingAt date: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .all:
            return nil
        case .last24Hours:
            return DateInterval(start: date.addingTimeInterval(-24 * 60 * 60), end: date)
        case .last7Days, .last30Days:
            let dayCount = self == .last7Days ? 7 : 30
            let endDay = calendar.startOfDay(for: date)
            guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: endDay),
                  let end = calendar.date(byAdding: .day, value: 1, to: endDay)
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
