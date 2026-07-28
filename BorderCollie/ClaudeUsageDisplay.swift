import Foundation

enum ClaudeUsageLimitKind: String, CaseIterable, Identifiable, Sendable {
    case fiveHour = "five_hour"
    case week = "seven_day"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour:
            "5h"
        case .week:
            "Weekly"
        }
    }

    var compactTitle: String {
        switch self {
        case .fiveHour:
            "5h"
        case .week:
            "7d"
        }
    }
}

enum ClaudeUsageLimitDisplay {
    static func usageLimits(from quota: SubscriptionQuota) -> [UsageLimitDisplay] {
        ClaudeUsageLimitKind.allCases.map { kind in
            UsageLimitDisplay(
                id: kind.id,
                title: kind.title,
                tier: quota.tiers.first { $0.name == kind.rawValue },
                resetStyle: kind == .fiveHour ? .time : .date
            )
        }
    }

    static func compactSummary(from quota: SubscriptionQuota) -> String {
        ClaudeUsageLimitKind.allCases
            .map { kind in
                let tier = quota.tiers.first { $0.name == kind.rawValue }
                return "\(kind.compactTitle): \(CompactUsageDisplay.percentageText(for: tier))"
            }
            .joined(separator: " | ")
    }
}
