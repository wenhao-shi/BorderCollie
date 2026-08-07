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

    /// Tier name for a model-scoped weekly window, e.g. `seven_day_opus`.
    static func modelWeekTierName(model: String) -> String {
        "\(week.rawValue)_\(model)"
    }

    /// Model name carried by a model-scoped weekly tier, or nil for the plain
    /// account-wide windows.
    static func modelName(fromTierName name: String) -> String? {
        let prefix = "\(week.rawValue)_"
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let model = String(name.dropFirst(prefix.count))
        return model.isEmpty ? nil : model
    }

    static func modelDisplayName(_ model: String) -> String {
        model
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(\.capitalized)
            .joined(separator: " ")
    }
}

enum ClaudeUsageLimitDisplay {
    /// The two account-wide windows are always shown — a missing one renders as
    /// `--` rather than silently disappearing — followed by whatever
    /// model-scoped weekly windows the account actually has.
    static func usageLimits(from quota: SubscriptionQuota) -> [UsageLimitDisplay] {
        let fixed = ClaudeUsageLimitKind.allCases.map { kind in
            UsageLimitDisplay(
                id: kind.id,
                title: kind.title,
                tier: quota.tiers.first { $0.name == kind.rawValue }
            )
        }

        let modelLimits = modelTiers(in: quota).map { tier, model in
            UsageLimitDisplay(
                id: tier.name,
                title: "7d · \(ClaudeUsageLimitKind.modelDisplayName(model))",
                tier: tier
            )
        }

        return fixed + modelLimits
    }

    static func compactSummary(from quota: SubscriptionQuota) -> String {
        let fixed = ClaudeUsageLimitKind.allCases.map { kind in
            let tier = quota.tiers.first { $0.name == kind.rawValue }
            return "\(kind.compactTitle): \(CompactUsageDisplay.percentageText(for: tier))"
        }

        let models = modelTiers(in: quota).map { tier, model in
            "\(ClaudeUsageLimitKind.modelDisplayName(model)): \(CompactUsageDisplay.percentageText(for: tier))"
        }

        return (fixed + models).joined(separator: " | ")
    }

    private static func modelTiers(in quota: SubscriptionQuota) -> [(tier: QuotaTier, model: String)] {
        quota.tiers.compactMap { tier in
            ClaudeUsageLimitKind.modelName(fromTierName: tier.name).map { (tier, $0) }
        }
    }
}
