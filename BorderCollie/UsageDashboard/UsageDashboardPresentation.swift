import Foundation

enum UsageChartMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        }
    }
}

enum UsageBreakdownMode: String, CaseIterable, Identifiable {
    case model
    case day

    var id: String { rawValue }

    var label: String {
        switch self {
        case .model: "Model"
        case .day: "Day"
        }
    }
}

struct UsageAgentSummary: Identifiable, Equatable {
    var id: UsageAgent { agent }

    let agent: UsageAgent
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let completeEvents: Int
    let pricedEvents: Int

    var hasPartialPricing: Bool {
        pricedEvents < completeEvents
    }
}

struct UsageDayBreakdown: Identifiable, Equatable {
    var id: Date { day }

    let day: Date
    let inputTokens: Int64
    let cacheWriteTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    let estimatedCostNanodollars: Int64
    let completeEvents: Int
    let pricedEvents: Int

    var hasPartialPricing: Bool {
        pricedEvents < completeEvents
    }

    var inputCacheHitRate: Double? {
        let observedInput = inputTokens + cacheWriteTokens + cacheReadTokens
        return observedInput == 0 ? nil : Double(cacheReadTokens) / Double(observedInput)
    }

    var outputShare: Double? {
        totalTokens == 0 ? nil : Double(outputTokens) / Double(totalTokens)
    }
}

enum UsageDashboardPresentation {
    static func agentSummaries(from aggregate: UsageAggregate) -> [UsageAgentSummary] {
        UsageAgent.dashboardOrder.compactMap { agent in
            let rows = aggregate.models.filter { $0.agent == agent }
            let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
            guard totalTokens > 0 else { return nil }
            return UsageAgentSummary(
                agent: agent,
                totalTokens: totalTokens,
                estimatedCostNanodollars: rows.reduce(0) { $0 + $1.estimatedCostNanodollars },
                completeEvents: rows.reduce(0) { $0 + $1.completeEvents },
                pricedEvents: rows.reduce(0) { $0 + $1.pricedEvents }
            )
        }
    }

    static func chartAgents(from aggregate: UsageAggregate, metric: UsageChartMetric) -> [UsageAgent] {
        UsageAgent.dashboardOrder.filter { agent in
            aggregate.chartPoints.contains { point in
                guard point.agent == agent else { return false }
                switch metric {
                case .cost:
                    return point.estimatedCostNanodollars > 0
                case .tokens:
                    return point.totalTokens > 0
                }
            }
        }
    }

    static func dayBreakdown(from aggregate: UsageAggregate) -> [UsageDayBreakdown] {
        let groups = Dictionary(grouping: aggregate.daily, by: \.day)
        return groups.map { day, points in
            UsageDayBreakdown(
                day: day,
                inputTokens: points.reduce(0) { $0 + $1.inputTokens },
                cacheWriteTokens: points.reduce(0) { $0 + $1.cacheWriteTokens },
                cacheReadTokens: points.reduce(0) { $0 + $1.cacheReadTokens },
                outputTokens: points.reduce(0) { $0 + $1.outputTokens },
                reasoningOutputTokens: points.reduce(0) { $0 + $1.reasoningOutputTokens },
                totalTokens: points.reduce(0) { $0 + $1.totalTokens },
                estimatedCostNanodollars: points.reduce(0) { $0 + $1.estimatedCostNanodollars },
                completeEvents: points.reduce(0) { $0 + $1.completeEvents },
                pricedEvents: points.reduce(0) { $0 + $1.pricedEvents }
            )
        }
        .sorted { $0.day > $1.day }
    }
}

enum UsageDashboardFormatting {
    static func tokens(_ value: Int64) -> String {
        compact(Double(value), units: [(1_000_000_000_000, "T"), (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")])
    }

    static func currency(nanodollars: Int64, compact: Bool = false) -> String {
        let dollars = Double(nanodollars) / 1_000_000_000
        if compact, abs(dollars) >= 1_000 {
            return "$" + self.compact(
                dollars,
                units: [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
            )
        }
        return dollars.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(abs(dollars) < 0.01 && dollars != 0 ? 4 : 2))
        )
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }

    static func interval(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let finalDay = interval.end.addingTimeInterval(-1)
        if calendar.isDate(interval.start, inSameDayAs: finalDay) {
            return interval.start.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(finalDay.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    static func rollingInterval(_ interval: DateInterval) -> String {
        let format = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day()
            .hour(.defaultDigits(amPM: .abbreviated))
            .minute()
        return "\(interval.start.formatted(format)) – \(interval.end.formatted(format))"
    }

    static func date(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func dateAndTime(_ value: Date) -> String {
        value.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute()
        )
    }

    private static func compact(_ value: Double, units: [(Double, String)]) -> String {
        for (divisor, suffix) in units where abs(value) >= divisor {
            let scaled = value / divisor
            let precision = abs(scaled) >= 100 ? 0 : (abs(scaled) >= 10 ? 1 : 2)
            return scaled.formatted(.number.precision(.fractionLength(0...precision))) + suffix
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
