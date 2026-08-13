import Foundation

enum UsageAgent: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case openCode = "opencode"
    case pi

    var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        case .openCode:
            "OpenCode"
        case .pi:
            "Pi"
        }
    }
}

enum PricingAuthority: String, Codable, Sendable {
    case anthropic
    case openAI = "openai"
    case unknown
}

enum UsageCompleteness: String, Codable, Sendable {
    case complete
    case partial
}

enum UsageNormalizationError: Error, Equatable, Sendable {
    case negativeToken(field: String, value: Int64)
    case arithmeticOverflow
    case reasoningExceedsOutput(reasoning: Int64, output: Int64)
}

struct UsageEvent: Equatable, Sendable, Identifiable {
    let id: String
    let agent: UsageAgent
    let pricingAuthority: PricingAuthority
    let rawProviderID: String?
    let rawModelID: String
    let canonicalModelID: String?
    let occurredAtMilliseconds: Int64

    let inputTokens: Int64?
    let cacheWriteTokens: Int64?
    let cacheWrite5mTokens: Int64?
    let cacheWrite1hTokens: Int64?
    let cacheReadTokens: Int64?
    let outputTokens: Int64?
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64?
    let sourceTotalTokens: Int64?

    let sourceReportedCostNanodollars: Int64?
    var estimatedAPICostNanodollars: Int64?
    var pricingRuleID: String?
    let completeness: UsageCompleteness
    let incompleteReason: String?

    let sourceKey: String
    let sourceID: String
    let sourceSchemaVersion: String
    let importerVersion: Int

    var occurredAt: Date {
        Date(timeIntervalSince1970: TimeInterval(occurredAtMilliseconds) / 1_000)
    }

    static func normalized(
        agent: UsageAgent,
        pricingAuthority: PricingAuthority,
        rawProviderID: String?,
        rawModelID: String,
        canonicalModelID: String?,
        occurredAtMilliseconds: Int64,
        inputTokens: Int64?,
        cacheWriteTokens: Int64?,
        cacheWrite5mTokens: Int64? = nil,
        cacheWrite1hTokens: Int64? = nil,
        cacheReadTokens: Int64?,
        outputTokens: Int64?,
        reasoningOutputTokens: Int64? = nil,
        sourceTotalTokens: Int64?,
        sourceReportedCostNanodollars: Int64? = nil,
        sourceKey: String,
        sourceID: String,
        sourceSchemaVersion: String,
        importerVersion: Int
    ) throws -> UsageEvent {
        let fields: [(String, Int64?)] = [
            ("in", inputTokens),
            ("cache-write", cacheWriteTokens),
            ("cache-write-5m", cacheWrite5mTokens),
            ("cache-write-1h", cacheWrite1hTokens),
            ("cache-read", cacheReadTokens),
            ("out", outputTokens),
            ("reasoning", reasoningOutputTokens),
            ("source-total", sourceTotalTokens),
        ]

        for (field, value) in fields {
            if let value, value < 0 {
                throw UsageNormalizationError.negativeToken(field: field, value: value)
            }
        }

        if let reasoningOutputTokens, let outputTokens, reasoningOutputTokens > outputTokens {
            throw UsageNormalizationError.reasoningExceedsOutput(
                reasoning: reasoningOutputTokens,
                output: outputTokens
            )
        }

        let required: [(String, Int64?)] = [
            ("in", inputTokens),
            ("cache-write", cacheWriteTokens),
            ("cache-read", cacheReadTokens),
            ("out", outputTokens),
        ]
        let missing = required.compactMap { name, value in value == nil ? name : nil }

        let computedTotal: Int64?
        if missing.isEmpty {
            computedTotal = try safeSum(required.compactMap { $0.1 })
        } else {
            computedTotal = nil
        }

        let completeness: UsageCompleteness
        let incompleteReason: String?
        if !missing.isEmpty {
            completeness = .partial
            incompleteReason = "Missing token buckets: \(missing.joined(separator: ", "))"
        } else if let sourceTotalTokens, sourceTotalTokens != computedTotal {
            completeness = .partial
            incompleteReason = "Source total does not match normalized token buckets"
        } else {
            completeness = .complete
            incompleteReason = nil
        }

        return UsageEvent(
            id: "\(agent.rawValue):\(sourceID)",
            agent: agent,
            pricingAuthority: pricingAuthority,
            rawProviderID: rawProviderID,
            rawModelID: rawModelID,
            canonicalModelID: canonicalModelID,
            occurredAtMilliseconds: occurredAtMilliseconds,
            inputTokens: inputTokens,
            cacheWriteTokens: cacheWriteTokens,
            cacheWrite5mTokens: cacheWrite5mTokens,
            cacheWrite1hTokens: cacheWrite1hTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: computedTotal,
            sourceTotalTokens: sourceTotalTokens,
            sourceReportedCostNanodollars: sourceReportedCostNanodollars,
            estimatedAPICostNanodollars: nil,
            pricingRuleID: nil,
            completeness: completeness,
            incompleteReason: incompleteReason,
            sourceKey: sourceKey,
            sourceID: sourceID,
            sourceSchemaVersion: sourceSchemaVersion,
            importerVersion: importerVersion
        )
    }

    private static func safeSum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else {
                throw UsageNormalizationError.arithmeticOverflow
            }
            return sum
        }
    }
}

struct UsageImportCheckpoint: Equatable, Sendable {
    let agent: UsageAgent
    let sourceKey: String
    let sourceIdentity: String
    let sourceSize: Int64
    let modifiedAtMilliseconds: Int64
    let byteOffset: Int64
    let highWatermark: String?
    let importerVersion: Int
}

enum UsageImportIssueSeverity: String, Sendable {
    case warning
    case error
}

struct UsageImportIssue: Equatable, Sendable {
    let agent: UsageAgent
    let sourceKey: String?
    let severity: UsageImportIssueSeverity
    let message: String
}

struct UsageImportBatch: Sendable {
    let agent: UsageAgent
    var events: [UsageEvent]
    var checkpoints: [UsageImportCheckpoint]
    var resetSourceKeys: Set<String>
    var removedSourceKeys: Set<String>
    var issues: [UsageImportIssue]

    init(agent: UsageAgent) {
        self.agent = agent
        events = []
        checkpoints = []
        resetSourceKeys = []
        removedSourceKeys = []
        issues = []
    }
}

struct UsageAgentImportReport: Equatable, Sendable {
    let agent: UsageAgent
    let importedEvents: Int
    let issues: [UsageImportIssue]
}

struct UsageImportReport: Equatable, Sendable {
    let agents: [UsageAgentImportReport]
    let finishedAtMilliseconds: Int64
}

struct UsagePricingRule: Equatable, Sendable, Identifiable {
    let id: String
    let authority: PricingAuthority
    let canonicalModelID: String
    let effectiveFromMilliseconds: Int64
    let effectiveUntilMilliseconds: Int64?
    let inputRateNanodollarsPerToken: Int64
    let cacheWriteRateNanodollarsPerToken: Int64?
    let cacheWrite5mRateNanodollarsPerToken: Int64?
    let cacheWrite1hRateNanodollarsPerToken: Int64?
    let cacheReadRateNanodollarsPerToken: Int64
    let outputRateNanodollarsPerToken: Int64
    let longContextThresholdTokens: Int64?
    let longContextInputMultiplierNumerator: Int64
    let longContextInputMultiplierDenominator: Int64
    let longContextOutputMultiplierNumerator: Int64
    let longContextOutputMultiplierDenominator: Int64
    let sourceURL: String
    let retrievedAtMilliseconds: Int64
}

struct UsageModelAlias: Equatable, Sendable {
    let authority: PricingAuthority
    let rawModelID: String
    let canonicalModelID: String
    let effectiveFromMilliseconds: Int64
    let effectiveUntilMilliseconds: Int64?
    let sourceURL: String
}

enum UsagePricingUnavailableReason: String, Equatable, Sendable {
    case partialTokens = "partial_tokens"
    case unknownModel = "unknown_model"
    case missingCacheWriteRate = "missing_cache_write_rate"
    case arithmeticOverflow = "arithmetic_overflow"
}

enum UsagePricingResult: Equatable, Sendable {
    case priced(costNanodollars: Int64, ruleID: String)
    case unavailable(UsagePricingUnavailableReason)
}

enum UsageDateRange: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    var shortLabel: String {
        switch self {
        case .oneDay: "24h"
        case .sevenDays, .thirtyDays: "\(rawValue)d"
        }
    }
}

struct UsageChartPoint: Equatable, Sendable, Identifiable {
    var id: String { "\(agent.rawValue):\(timestamp.timeIntervalSince1970)" }

    let timestamp: Date
    let agent: UsageAgent
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let completeEvents: Int
    let pricedEvents: Int
}

struct UsageDailyPoint: Equatable, Sendable, Identifiable {
    var id: String { "\(agent.rawValue):\(day.timeIntervalSince1970)" }

    let day: Date
    let agent: UsageAgent
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

struct UsageModelBreakdown: Equatable, Sendable, Identifiable {
    var id: String { "\(agent.rawValue):\(modelID)" }

    let agent: UsageAgent
    let modelID: String
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

struct UsageCoverage: Equatable, Sendable {
    let totalEvents: Int
    let completeEvents: Int
    let pricedEvents: Int
    let partialEvents: Int
    let unpricedCompleteEvents: Int
}

struct UsageAggregate: Equatable, Sendable {
    let range: UsageDateRange
    let interval: DateInterval
    let agents: Set<UsageAgent>
    let inputTokens: Int64
    let cacheWriteTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let inputCacheHitRate: Double?
    let outputShare: Double?
    let chartPoints: [UsageChartPoint]
    let daily: [UsageDailyPoint]
    let models: [UsageModelBreakdown]
    let coverage: UsageCoverage
}
