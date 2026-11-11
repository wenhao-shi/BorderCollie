import Foundation

enum ClaudeUsageLimitKind: String, CaseIterable, Identifiable, Sendable {
    case fiveHour = "five_hour"
    case week = "seven_day"
    /// Fable's model-scoped weekly window. Pinned like the account-wide windows
    /// so a Fable plan always shows it — as `--` when the API omits it.
    case fableWeek = "seven_day_fable"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour:
            "5h"
        case .week:
            "7d"
        case .fableWeek:
            "7d · Fable"
        }
    }

    var compactTitle: String {
        switch self {
        case .fiveHour:
            "5h"
        case .week:
            "7d"
        case .fableWeek:
            "Fable"
        }
    }

    /// Model families the usage API scopes weekly windows to. A raw model name
    /// containing one of these collapses to it, so `seven_day_fable`, a
    /// `limits` entry for `claude-fable-5-2`, and one displayed as
    /// "Claude Fable 5.2" all land on the same `fable` tier.
    private static let modelFamilies: Set<String> = ["fable", "mythos", "opus", "sonnet", "haiku"]

    static func normalizedModelName(_ raw: String) -> String {
        let words = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
            .map(String.init)
        if let family = words.first(where: modelFamilies.contains) {
            return family
        }
        return words.joined(separator: "_")
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
    /// The account-wide windows and Fable's weekly window are always shown — a missing one renders as
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

    /// Model-scoped weekly windows not already pinned as a fixed kind.
    private static func modelTiers(in quota: SubscriptionQuota) -> [(tier: QuotaTier, model: String)] {
        let fixedNames = Set(ClaudeUsageLimitKind.allCases.map(\.rawValue))
        return quota.tiers.compactMap { tier in
            guard !fixedNames.contains(tier.name) else { return nil }
            return ClaudeUsageLimitKind.modelName(fromTierName: tier.name).map { (tier, $0) }
        }
    }
}
