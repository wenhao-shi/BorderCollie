import SwiftUI

struct UsageBreakdownTable: View {
    let aggregate: UsageAggregate
    @Binding var mode: UsageBreakdownMode

    @State private var sortOrder = [KeyPathComparator(\Row.totalTokens, order: .reverse)]
    @State private var columnCustomization = TableColumnCustomization<Row>()

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
            HStack {
                Text("Breakdown")
                    .font(.headline)

                Spacer()

                Picker("Breakdown grouping", selection: $mode) {
                    ForEach(UsageBreakdownMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Table(rows, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                TableColumn(mode == .model ? "Model" : "Day", value: \.title) { row in
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
                .customizationID("title")

                TableColumn("Total", value: \.totalTokens) { row in
                    tokenText(row.totalTokens)
                }
                .width(min: 70, ideal: 90)
                .customizationID("total")

                TableColumn("In", value: \.inputTokens) { row in
                    tokenText(row.inputTokens)
                }
                .width(min: 65, ideal: 82)
                .customizationID("in")

                TableColumn("Cache write", value: \.cacheWriteTokens) { row in
                    tokenText(row.cacheWriteTokens)
                }
                .width(min: 82, ideal: 105)
                .customizationID("cacheWrite")

                TableColumn("Cache read", value: \.cacheReadTokens) { row in
                    tokenText(row.cacheReadTokens)
                }
                .width(min: 82, ideal: 105)
                .customizationID("cacheRead")

                TableColumn("Out", value: \.outputTokens) { row in
                    tokenText(row.outputTokens)
                        .help(
                            row.reasoningOutputTokens > 0
                                ? "Includes \(UsageDashboardFormatting.tokens(row.reasoningOutputTokens)) reasoning tokens."
                                : "Output tokens"
                        )
                }
                .width(min: 65, ideal: 82)
                .customizationID("out")

                TableColumn("Cost", value: \.costNanodollars) { row in
                    Text(row.costText)
                        .monospacedDigit()
                        .foregroundStyle(row.hasPartialPricing ? .secondary : .primary)
                        .help(row.hasPartialPricing ? "This subtotal excludes unpriced events." : "All complete events in this row are priced.")
                }
                .width(min: 85, ideal: 110)
                .customizationID("cost")

                TableColumn("Cost share", value: \.costNanodollars) { row in
                    Text(row.costShareText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 88)
                .customizationID("costShare")

                TableColumn("Input cache hit", value: \.sortableInputCacheHitRate) { row in
                    Text(UsageDashboardFormatting.percent(row.inputCacheHitRate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("cache-read ÷ observed input")
                }
                .width(min: 95, ideal: 115)
                .customizationID("inputCacheHit")

                TableColumn("Output share", value: \.sortableOutputShare) { row in
                    Text(UsageDashboardFormatting.percent(row.outputShare))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("out ÷ total")
                }
                .width(min: 90, ideal: 105)
                .customizationID("outputShare")
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: tableHeight)
        }
    }

    private var rows: [Row] {
        let unsorted: [Row]
        switch mode {
        case .model:
            unsorted = aggregate.models.filter { $0.totalTokens > 0 }.map { item in
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
            unsorted = UsageDashboardPresentation.dayBreakdown(from: aggregate).map { item in
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
        return unsorted.sorted(using: sortOrder)
    }

    /// Sized to its rows so the table does not open a second scroll region
    /// inside the page's. Thirty days of rows fit without one.
    private var tableHeight: CGFloat {
        let header: CGFloat = 28
        let row: CGFloat = 30
        return min(max(CGFloat(rows.count) * row + header, 220), 980)
    }

    private func tokenText(_ value: Int64) -> some View {
        Text(UsageDashboardFormatting.tokens(value))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    fileprivate struct Row: Identifiable {
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

        /// `KeyPathComparator` needs a non-optional key path; rows with no
        /// observed input sort below every real ratio rather than alongside 0%.
        var sortableInputCacheHitRate: Double { inputCacheHitRate ?? -1 }
        var sortableOutputShare: Double { outputShare ?? -1 }
    }
}
