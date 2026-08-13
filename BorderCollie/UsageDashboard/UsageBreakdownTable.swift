import SwiftUI

struct UsageBreakdownTable: View {
    let aggregate: UsageAggregate
    @Binding var mode: UsageBreakdownMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.headline)

                Spacer()

                Picker("Breakdown grouping", selection: $mode) {
                    ForEach(UsageBreakdownMode.allCases) { option in
                        Text(option.label.uppercased()).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            Table(rows) {
                TableColumn(mode == .model ? "Model" : "Day") { row in
                    HStack(spacing: 9) {
                        if let agent = row.agent {
                            UsageAgentIconView(agent: agent, size: 15)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .lineLimit(1)
                            if let agent = row.agent {
                                Text(agent.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .width(min: 220, ideal: 420)

                TableColumn("Total") { row in
                    tokenText(row.totalTokens)
                }
                .width(min: 70, ideal: 90)

                TableColumn("In") { row in
                    tokenText(row.inputTokens)
                }
                .width(min: 65, ideal: 82)

                TableColumn("Cache write") { row in
                    tokenText(row.cacheWriteTokens)
                }
                .width(min: 82, ideal: 105)

                TableColumn("Cache read") { row in
                    tokenText(row.cacheReadTokens)
                }
                .width(min: 82, ideal: 105)

                TableColumn("Out") { row in
                    tokenText(row.outputTokens)
                        .help(
                            row.reasoningOutputTokens > 0
                                ? "Includes \(UsageDashboardFormatting.tokens(row.reasoningOutputTokens)) reasoning tokens."
                                : "Output tokens"
                        )
                }
                .width(min: 65, ideal: 82)

                TableColumn("Cost") { row in
                    Text(row.costText)
                        .monospacedDigit()
                        .foregroundStyle(row.hasPartialPricing ? .secondary : .primary)
                        .help(row.hasPartialPricing ? "This subtotal excludes unpriced events." : "All complete events in this row are priced.")
                }
                .width(min: 85, ideal: 110)

                TableColumn("Cost share") { row in
                    Text(row.costShareText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 88)

                TableColumn("Input cache hit") { row in
                    Text(UsageDashboardFormatting.percent(row.inputCacheHitRate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("cache-read ÷ observed input")
                }
                .width(min: 95, ideal: 115)

                TableColumn("Output share") { row in
                    Text(UsageDashboardFormatting.percent(row.outputShare))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("out ÷ total")
                }
                .width(min: 90, ideal: 105)
            }
            .frame(minHeight: 220, idealHeight: tableHeight, maxHeight: tableHeight)
        }
    }

    private var rows: [Row] {
        switch mode {
        case .model:
            return aggregate.models.filter { $0.totalTokens > 0 }.map { item in
                Row(
                    id: item.id,
                    title: item.modelID,
                    agent: item.agent,
                    inputTokens: item.inputTokens,
                    cacheWriteTokens: item.cacheWriteTokens,
                    cacheReadTokens: item.cacheReadTokens,
                    outputTokens: item.outputTokens,
                    reasoningOutputTokens: item.reasoningOutputTokens,
                    totalTokens: item.totalTokens,
                    costNanodollars: item.estimatedCostNanodollars,
                    completeEvents: item.completeEvents,
                    pricedEvents: item.pricedEvents,
                    aggregateCostNanodollars: aggregate.estimatedCostNanodollars
                )
            }
        case .day:
            return UsageDashboardPresentation.dayBreakdown(from: aggregate).map { item in
                Row(
                    id: String(item.day.timeIntervalSince1970),
                    title: UsageDashboardFormatting.date(item.day),
                    agent: nil,
                    inputTokens: item.inputTokens,
                    cacheWriteTokens: item.cacheWriteTokens,
                    cacheReadTokens: item.cacheReadTokens,
                    outputTokens: item.outputTokens,
                    reasoningOutputTokens: item.reasoningOutputTokens,
                    totalTokens: item.totalTokens,
                    costNanodollars: item.estimatedCostNanodollars,
                    completeEvents: item.completeEvents,
                    pricedEvents: item.pricedEvents,
                    aggregateCostNanodollars: aggregate.estimatedCostNanodollars
                )
            }
        }
    }

    private var tableHeight: CGFloat {
        min(max(CGFloat(rows.count) * 42 + 32, 220), 460)
    }

    private func tokenText(_ value: Int64) -> some View {
        Text(UsageDashboardFormatting.tokens(value))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let agent: UsageAgent?
        let inputTokens: Int64
        let cacheWriteTokens: Int64
        let cacheReadTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64
        let totalTokens: Int64
        let costNanodollars: Int64
        let completeEvents: Int
        let pricedEvents: Int
        let aggregateCostNanodollars: Int64

        var hasPartialPricing: Bool {
            pricedEvents < completeEvents
        }

        var costText: String {
            if completeEvents > 0, pricedEvents == 0 {
                return "Unpriced"
            }
            return UsageDashboardFormatting.currency(nanodollars: costNanodollars) + (hasPartialPricing ? "*" : "")
        }

        var costShareText: String {
            guard aggregateCostNanodollars > 0 else { return "—" }
            return UsageDashboardFormatting.percent(
                Double(costNanodollars) / Double(aggregateCostNanodollars)
            )
        }

        var inputCacheHitRate: Double? {
            let observedInput = inputTokens + cacheWriteTokens + cacheReadTokens
            return observedInput == 0 ? nil : Double(cacheReadTokens) / Double(observedInput)
        }

        var outputShare: Double? {
            totalTokens == 0 ? nil : Double(outputTokens) / Double(totalTokens)
        }
    }
}
