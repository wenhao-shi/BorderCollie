import Foundation

/// Formats a reset timestamp with the precision its distance warrants.
///
/// Precision tracks how close the reset is, not how long the window nominally
/// is. Keying off window length is only a proxy and it breaks at the edges: a
/// seven-day window resetting in twenty minutes would read "Thu", and a monthly
/// cycle on its last day would read "Aug 20" when it resets in two hours.
enum UsageResetFormatting {
    static func text(
        forResetsAt resetsAt: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String? {
        guard
            let resetsAt,
            let resetDate = ISO8601DateFormatter.codex.dateAllowingCodexFormats(from: resetsAt)
        else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Compare whole days so the boundary follows the calendar rather than a
        // rolling 24-hour offset from the current instant.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: resetDate)
        ).day ?? 0

        if days == 0 {
            return formatter(timeZone: timeZone) {
                $0.dateStyle = .none
                $0.timeStyle = .short
            }.string(from: resetDate)
        }

        if (1...6).contains(days) {
            // Minutes stay in: reset times are not always on the hour, and
            // "Thu 8 PM" for 8:47 would be wrong rather than merely coarse.
            return formatter(timeZone: timeZone) {
                $0.setLocalizedDateFormatFromTemplate("EEE j:mm")
            }.string(from: resetDate)
        }

        return formatter(timeZone: timeZone) {
            $0.setLocalizedDateFormatFromTemplate("MMM d")
        }.string(from: resetDate)
    }

    private static func formatter(
        timeZone: TimeZone,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        configure(formatter)
        return formatter
    }
}

struct UsageLimitDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let tier: QuotaTier?

    var remainingPercentage: Double { remainingPercentage(from: tier?.utilization) }
    var resetsAt: String? { tier?.resetsAt }

    var percentageText: String {
        guard tier != nil else {
            return "--"
        }

        return "\(remainingPercentage.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    func resetText(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        UsageResetFormatting.text(forResetsAt: resetsAt, now: now, timeZone: timeZone)
    }

    private func remainingPercentage(from usedPercentage: Double?) -> Double {
        guard let usedPercentage else {
            return 0
        }

        return min(max(100 - usedPercentage, 0), 100)
    }
}

enum CodexUsageLimitKind: String, CaseIterable, Identifiable, Sendable {
    case fiveHour = "five_hour"
    case week = "seven_day"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour:
            "5h"
        case .week:
            "7d"
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

struct CodexUsageLimitDisplay: Identifiable, Equatable, Sendable {
    let kind: CodexUsageLimitKind
    let tier: QuotaTier?

    var id: String { kind.id }
    var title: String { kind.title }
    var remainingPercentage: Double { remainingPercentage(from: tier?.utilization) }
    var resetsAt: String? { tier?.resetsAt }

    var percentageText: String {
        guard tier != nil else {
            return "--"
        }

        return "\(remainingPercentage.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    func resetText(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        UsageResetFormatting.text(forResetsAt: resetsAt, now: now, timeZone: timeZone)
    }

    static func expectedLimits(from quota: SubscriptionQuota) -> [CodexUsageLimitDisplay] {
        CodexUsageLimitKind.allCases.map { kind in
            CodexUsageLimitDisplay(
                kind: kind,
                tier: quota.tiers.first { $0.name == kind.rawValue }
            )
        }
    }

    static func usageLimits(from quota: SubscriptionQuota) -> [UsageLimitDisplay] {
        expectedLimits(from: quota).map { limit in
            UsageLimitDisplay(
                id: limit.id,
                title: limit.title,
                tier: limit.tier
            )
        }
    }

    static func compactSummary(from quota: SubscriptionQuota) -> String {
        expectedLimits(from: quota)
            .map { "\($0.kind.compactTitle): \(CompactUsageDisplay.percentageText(for: $0.tier))" }
            .joined(separator: " | ")
    }

    private func remainingPercentage(from usedPercentage: Double?) -> Double {
        guard let usedPercentage else {
            return 0
        }

        return min(max(100 - usedPercentage, 0), 100)
    }


}

enum CompactUsageDisplay {
    static func percentageText(for tier: QuotaTier?) -> String {
        guard let tier else {
            return "--"
        }

        let remaining = min(max(100 - tier.utilization, 0), 100)
        return "\(Int(remaining.rounded()))%"
    }

}
