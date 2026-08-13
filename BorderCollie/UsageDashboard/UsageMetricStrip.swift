import SwiftUI

struct UsageMetricStrip: View {
    let aggregate: UsageAggregate

    var body: some View {
        ViewThatFits(in: .horizontal) {
            metricGrid(columnCount: 8)
            metricGrid(columnCount: 4)
            metricGrid(columnCount: 2)
            metricGrid(columnCount: 1)
        }
    }

    private func metricGrid(columnCount: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 155), spacing: 1),
                count: columnCount
            ),
            spacing: 1
        ) {
            metric("Total", UsageDashboardFormatting.tokens(aggregate.totalTokens), "complete tokens")
            metric("In", UsageDashboardFormatting.tokens(aggregate.inputTokens), "uncached input")
            metric("Cache write", UsageDashboardFormatting.tokens(aggregate.cacheWriteTokens), "new cached input")
            metric("Cache read", UsageDashboardFormatting.tokens(aggregate.cacheReadTokens), "served from cache")
            metric(
                "Out",
                UsageDashboardFormatting.tokens(aggregate.outputTokens),
                aggregate.reasoningOutputTokens > 0
                    ? "includes \(UsageDashboardFormatting.tokens(aggregate.reasoningOutputTokens)) reasoning"
                    : "billed output"
            )
            metric(
                "Cost",
                UsageDashboardFormatting.currency(nanodollars: aggregate.estimatedCostNanodollars),
                "\(aggregate.coverage.pricedEvents) of \(aggregate.coverage.completeEvents) events priced"
            )
            metric(
                "Input cache hit",
                UsageDashboardFormatting.percent(aggregate.inputCacheHitRate),
                "cache-read ÷ observed input"
            )
            metric(
                "Output share",
                UsageDashboardFormatting.percent(aggregate.outputShare),
                "out ÷ total"
            )
        }
        .frame(minWidth: minimumWidth(for: columnCount))
        .padding(1)
        .background(.separator.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func minimumWidth(for columnCount: Int) -> CGFloat {
        CGFloat(columnCount * 155 + (columnCount - 1))
    }

    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
    }
}
