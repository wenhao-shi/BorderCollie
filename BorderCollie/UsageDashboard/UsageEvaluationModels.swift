import Foundation

enum UsageTimingQuality: String, Codable, Sendable {
    case exact
    case inferred
}

enum UsageTimingError: Error, Equatable, Sendable {
    case invalidInterval(start: Int64, end: Int64)
}

struct UsageActiveTurn: Equatable, Sendable, Identifiable {
    let id: String
    let agent: UsageAgent
    let sessionKey: String
    let pricingAuthority: PricingAuthority
    let rawModelID: String
    let canonicalModelID: String?
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64
    let timingQuality: UsageTimingQuality
    let sourceKey: String
    let sourceID: String
    let importerVersion: Int

    var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAtMilliseconds) / 1_000)
    }

    var endedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(endedAtMilliseconds) / 1_000)
    }

    var durationMilliseconds: Int64 {
        endedAtMilliseconds - startedAtMilliseconds
    }

    static func normalized(
        agent: UsageAgent,
        sessionKey: String,
        pricingAuthority: PricingAuthority,
        rawModelID: String,
        canonicalModelID: String?,
        startedAtMilliseconds: Int64,
        endedAtMilliseconds: Int64,
        timingQuality: UsageTimingQuality,
        sourceKey: String,
        sourceID: String,
        importerVersion: Int
    ) throws -> UsageActiveTurn {
        guard endedAtMilliseconds >= startedAtMilliseconds else {
            throw UsageTimingError.invalidInterval(start: startedAtMilliseconds, end: endedAtMilliseconds)
        }
        return UsageActiveTurn(
            id: "\(agent.rawValue):\(sourceID)",
            agent: agent,
            sessionKey: sessionKey,
            pricingAuthority: pricingAuthority,
            rawModelID: rawModelID,
            canonicalModelID: canonicalModelID,
            startedAtMilliseconds: startedAtMilliseconds,
            endedAtMilliseconds: endedAtMilliseconds,
            timingQuality: timingQuality,
            sourceKey: sourceKey,
            sourceID: sourceID,
            importerVersion: importerVersion
        )
    }
}

struct EvaluationRun: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64?
    let createdAtMilliseconds: Int64

    var isActive: Bool { endedAtMilliseconds == nil }

    var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAtMilliseconds) / 1_000)
    }

    var endedAt: Date? {
        endedAtMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    func interval(endingAt fallbackEnd: Date = Date()) -> DateInterval? {
        let end = endedAt ?? fallbackEnd
        guard end >= startedAt else { return nil }
        return DateInterval(start: startedAt, end: end)
    }
}

struct EvaluationSessionSummary: Equatable, Sendable, Identifiable {
    var id: String { sessionKey }

    let sessionKey: String
    let agent: UsageAgent
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64
    let eventCount: Int
    let activeTurnCount: Int
    let modelIDs: [String]

    var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAtMilliseconds) / 1_000)
    }

    var endedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(endedAtMilliseconds) / 1_000)
    }
}

struct EvaluationTurnBreakdown: Equatable, Sendable, Identifiable {
    let id: String
    let agent: UsageAgent
    let sessionKey: String
    let modelID: String
    let startedAtMilliseconds: Int64
    let endedAtMilliseconds: Int64
    let durationMilliseconds: Int64
    let timingQuality: UsageTimingQuality
}

struct EvaluationModelBreakdown: Equatable, Sendable, Identifiable {
    var id: String { "\(agent.rawValue):\(modelID)" }

    let agent: UsageAgent
    let modelID: String
    let activeTimeMilliseconds: Int64
    let inputTokens: Int64
    let cacheWriteTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let completeEvents: Int
    let pricedEvents: Int
}

struct EvaluationTimingSummary: Equatable, Sendable {
    let additiveAgentTimeMilliseconds: Int64
    let effectiveWallTimeMilliseconds: Int64
    let humanIdleTimeMilliseconds: Int64
    let exactTurns: Int
    let inferredTurns: Int
}

struct UsageEvaluationReport: Equatable, Sendable {
    let run: EvaluationRun
    let availableSessions: [EvaluationSessionSummary]
    let selectedSessionKeys: Set<String>
    let inputTokens: Int64
    let cacheWriteTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let inputCacheHitRate: Double?
    let outputShare: Double?
    let models: [EvaluationModelBreakdown]
    let turns: [EvaluationTurnBreakdown]
    let timing: EvaluationTimingSummary
    let coverage: UsageCoverage
}
