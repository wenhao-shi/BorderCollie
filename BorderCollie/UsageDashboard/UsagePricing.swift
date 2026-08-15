import Foundation

enum UsageModelCatalog {
    static let aliases: [UsageModelAlias] = [
        anthropicAlias("claude-fable-5", "claude-fable-5", from: "2026-06-09T00:00:00Z"),
        anthropicAlias("claude-opus-5", "claude-opus-5", from: "2026-07-24T00:00:00Z"),
        anthropicAlias("claude-sonnet-5", "claude-sonnet-5", from: "2026-06-30T00:00:00Z"),
        anthropicAlias("claude-haiku-4-5-20251001", "claude-haiku-4.5", from: "2025-10-15T00:00:00Z"),
        openAIAlias("gpt-5.6", "gpt-5.6-sol", from: "2026-07-09T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol"),
        openAIAlias("gpt-5.6-sol", "gpt-5.6-sol", from: "2026-07-09T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol"),
        openAIAlias("gpt-5.6-terra", "gpt-5.6-terra", from: "2026-07-09T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.6-terra"),
        openAIAlias("gpt-5.6-luna", "gpt-5.6-luna", from: "2026-07-09T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.6-luna"),
        openAIAlias("gpt-5.5", "gpt-5.5", from: "2026-04-24T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.5"),
    ]

    static func authority(rawProviderID: String?) -> PricingAuthority {
        switch rawProviderID?.lowercased() {
        case "anthropic": .anthropic
        case "openai", "openai-codex": .openAI
        default: .unknown
        }
    }

    static func canonicalModelID(
        authority: PricingAuthority,
        rawModelID: String,
        occurredAtMilliseconds: Int64
    ) -> String? {
        if let exact = aliases.first(where: {
            $0.authority == authority
                && $0.rawModelID == rawModelID
                && occurredAtMilliseconds >= $0.effectiveFromMilliseconds
                && ($0.effectiveUntilMilliseconds == nil || occurredAtMilliseconds < $0.effectiveUntilMilliseconds!)
        }) {
            return exact.canonicalModelID
        }
        return nil
    }

    private static func anthropicAlias(_ raw: String, _ canonical: String, from: String) -> UsageModelAlias {
        UsageModelAlias(
            authority: .anthropic, rawModelID: raw, canonicalModelID: canonical,
            effectiveFromMilliseconds: try! UsageTimestampParser.milliseconds(from: from),
            effectiveUntilMilliseconds: nil,
            sourceURL: UsagePricingCatalog.anthropicSource
        )
    }

    private static func openAIAlias(_ raw: String, _ canonical: String, from: String, source: String) -> UsageModelAlias {
        UsageModelAlias(
            authority: .openAI, rawModelID: raw, canonicalModelID: canonical,
            effectiveFromMilliseconds: try! UsageTimestampParser.milliseconds(from: from),
            effectiveUntilMilliseconds: nil, sourceURL: source
        )
    }
}

enum UsagePricingCatalog {
    static let retrievedAtMilliseconds = iso("2026-08-15T00:00:00Z")
    static let anthropicSource = "https://platform.claude.com/docs/en/about-claude/pricing"

    static let rules: [UsagePricingRule] = [
        anthropic("anthropic-fable-5-2026", "claude-fable-5", from: "2026-06-09T00:00:00Z", input: 10_000, write5m: 12_500, write1h: 20_000, read: 1_000, output: 50_000),
        anthropic("anthropic-opus-5-2026", "claude-opus-5", from: "2026-07-24T00:00:00Z", input: 5_000, write5m: 6_250, write1h: 10_000, read: 500, output: 25_000),
        anthropic("anthropic-sonnet-5-standard", "claude-sonnet-5", from: "2026-06-30T00:00:00Z", input: 2_000, write5m: 2_500, write1h: 4_000, read: 200, output: 10_000),
        anthropic("anthropic-haiku-4.5", "claude-haiku-4.5", from: "2025-10-15T00:00:00Z", input: 1_000, write5m: 1_250, write1h: 2_000, read: 100, output: 5_000),
        openAI("openai-gpt-5.6-sol", "gpt-5.6-sol", from: "2026-07-09T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol", input: 5_000, write: 6_250, read: 500, output: 30_000),
        openAI("openai-gpt-5.6-terra-launch", "gpt-5.6-terra", from: "2026-07-09T00:00:00Z", until: "2026-07-30T00:00:00Z", source: "https://openai.com/index/gpt-5-6/", input: 2_500, write: 3_125, read: 250, output: 15_000),
        openAI("openai-gpt-5.6-terra", "gpt-5.6-terra", from: "2026-07-30T00:00:00Z", source: "https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/", input: 2_000, write: 2_500, read: 200, output: 12_000),
        openAI("openai-gpt-5.6-luna-launch", "gpt-5.6-luna", from: "2026-07-09T00:00:00Z", until: "2026-07-30T00:00:00Z", source: "https://openai.com/index/gpt-5-6/", input: 1_000, write: 1_250, read: 100, output: 6_000),
        openAI("openai-gpt-5.6-luna", "gpt-5.6-luna", from: "2026-07-30T00:00:00Z", source: "https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/", input: 200, write: 250, read: 20, output: 1_200),
        openAI("openai-gpt-5.5", "gpt-5.5", from: "2026-04-24T00:00:00Z", source: "https://developers.openai.com/api/docs/models/gpt-5.5", input: 5_000, write: nil, read: 500, output: 30_000),
    ]

    private static func anthropic(
        _ id: String,
        _ model: String,
        from: String,
        until: String? = nil,
        input: Int64,
        write5m: Int64,
        write1h: Int64,
        read: Int64,
        output: Int64
    ) -> UsagePricingRule {
        UsagePricingRule(
            id: id, authority: .anthropic, canonicalModelID: model,
            effectiveFromMilliseconds: iso(from), effectiveUntilMilliseconds: until.map { iso($0) },
            inputRateNanodollarsPerToken: input, cacheWriteRateNanodollarsPerToken: nil,
            cacheWrite5mRateNanodollarsPerToken: write5m, cacheWrite1hRateNanodollarsPerToken: write1h,
            cacheReadRateNanodollarsPerToken: read, outputRateNanodollarsPerToken: output,
            longContextThresholdTokens: nil,
            longContextInputMultiplierNumerator: 1, longContextInputMultiplierDenominator: 1,
            longContextOutputMultiplierNumerator: 1, longContextOutputMultiplierDenominator: 1,
            sourceURL: anthropicSource, retrievedAtMilliseconds: retrievedAtMilliseconds
        )
    }

    private static func openAI(
        _ id: String,
        _ model: String,
        from: String,
        until: String? = nil,
        source: String,
        input: Int64,
        write: Int64?,
        read: Int64,
        output: Int64
    ) -> UsagePricingRule {
        UsagePricingRule(
            id: id, authority: .openAI, canonicalModelID: model,
            effectiveFromMilliseconds: iso(from), effectiveUntilMilliseconds: until.map { iso($0) },
            inputRateNanodollarsPerToken: input, cacheWriteRateNanodollarsPerToken: write,
            cacheWrite5mRateNanodollarsPerToken: nil, cacheWrite1hRateNanodollarsPerToken: nil,
            cacheReadRateNanodollarsPerToken: read, outputRateNanodollarsPerToken: output,
            longContextThresholdTokens: 272_000,
            longContextInputMultiplierNumerator: 2, longContextInputMultiplierDenominator: 1,
            longContextOutputMultiplierNumerator: 3, longContextOutputMultiplierDenominator: 2,
            sourceURL: source, retrievedAtMilliseconds: retrievedAtMilliseconds
        )
    }

    private static func iso(_ value: String) -> Int64 {
        try! UsageTimestampParser.milliseconds(from: value)
    }
}

struct UsagePricingEngine: Sendable {
    let rules: [UsagePricingRule]

    init(rules: [UsagePricingRule] = UsagePricingCatalog.rules) {
        self.rules = rules
    }

    func price(_ event: UsageEvent) -> UsagePricingResult {
        guard event.completeness == .complete,
              let input = event.inputTokens,
              let cacheWrite = event.cacheWriteTokens,
              let cacheRead = event.cacheReadTokens,
              let output = event.outputTokens
        else { return .unavailable(.partialTokens) }
        guard let model = event.canonicalModelID,
              let rule = rules.last(where: {
                  $0.authority == event.pricingAuthority
                      && $0.canonicalModelID == model
                      && event.occurredAtMilliseconds >= $0.effectiveFromMilliseconds
                      && ($0.effectiveUntilMilliseconds == nil || event.occurredAtMilliseconds < $0.effectiveUntilMilliseconds!)
              })
        else { return .unavailable(.unknownModel) }

        let observedInput = [input, cacheWrite, cacheRead].checkedSum()
        guard let observedInput else { return .unavailable(.arithmeticOverflow) }
        let long = rule.longContextThresholdTokens.map { observedInput > $0 } ?? false
        let inputNumerator = long ? rule.longContextInputMultiplierNumerator : 1
        let inputDenominator = long ? rule.longContextInputMultiplierDenominator : 1
        let outputNumerator = long ? rule.longContextOutputMultiplierNumerator : 1
        let outputDenominator = long ? rule.longContextOutputMultiplierDenominator : 1

        var parts: [Int64] = []
        guard let inputCost = cost(tokens: input, rate: rule.inputRateNanodollarsPerToken, numerator: inputNumerator, denominator: inputDenominator),
              let readCost = cost(tokens: cacheRead, rate: rule.cacheReadRateNanodollarsPerToken, numerator: inputNumerator, denominator: inputDenominator),
              let outputCost = cost(tokens: output, rate: rule.outputRateNanodollarsPerToken, numerator: outputNumerator, denominator: outputDenominator)
        else { return .unavailable(.arithmeticOverflow) }
        parts.append(contentsOf: [inputCost, readCost, outputCost])

        if cacheWrite > 0 {
            if let combinedRate = rule.cacheWriteRateNanodollarsPerToken {
                guard let writeCost = cost(tokens: cacheWrite, rate: combinedRate, numerator: inputNumerator, denominator: inputDenominator) else {
                    return .unavailable(.arithmeticOverflow)
                }
                parts.append(writeCost)
            } else if let write5m = event.cacheWrite5mTokens,
                      let write1h = event.cacheWrite1hTokens,
                      [write5m, write1h].checkedSum() == cacheWrite,
                      let rate5m = rule.cacheWrite5mRateNanodollarsPerToken,
                      let rate1h = rule.cacheWrite1hRateNanodollarsPerToken,
                      let cost5m = cost(tokens: write5m, rate: rate5m, numerator: inputNumerator, denominator: inputDenominator),
                      let cost1h = cost(tokens: write1h, rate: rate1h, numerator: inputNumerator, denominator: inputDenominator) {
                parts.append(contentsOf: [cost5m, cost1h])
            } else {
                return .unavailable(.missingCacheWriteRate)
            }
        }

        guard let total = parts.checkedSum() else { return .unavailable(.arithmeticOverflow) }
        return .priced(costNanodollars: total, ruleID: rule.id)
    }

    private func cost(tokens: Int64, rate: Int64, numerator: Int64, denominator: Int64) -> Int64? {
        guard denominator > 0 else { return nil }
        let (base, firstOverflow) = tokens.multipliedReportingOverflow(by: rate)
        let (scaled, secondOverflow) = base.multipliedReportingOverflow(by: numerator)
        guard !firstOverflow, !secondOverflow, scaled % denominator == 0 else { return nil }
        return scaled / denominator
    }
}
