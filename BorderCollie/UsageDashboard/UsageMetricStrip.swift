import SwiftUI

/// Token accounting for the selected period.
///
/// These eight numbers are three different kinds of thing: two aggregates, four
/// buckets that sum to the first aggregate, and two ratios derived from the
/// buckets. Rendering them as eight identical tiles hid the arithmetic that
/// relates them, so the buckets are drawn as one proportional bar — the same
/// composition figure Storage settings uses — with their values beside it.
struct UsageMetricStrip: View {
    let aggregate: UsageAggregate

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.large) {
                totals
                Divider()
                composition
                Divider()
                ratios
            }
            .padding(UsageDesign.Spacing.small)
        } label: {
            Text("Token accounting")
                .font(.headline)
        }
    }

    private var totals: some View {
        HStack(alignment: .top, spacing: UsageDesign.Spacing.section) {
            MetricTile(
                title: "Total",
                value: UsageDashboardFormatting.tokens(aggregate.totalTokens),
                detail: "complete tokens"
            )
            MetricTile(
                title: "Cost",
                value: UsageDashboardFormatting.currency(nanodollars: aggregate.estimatedCostNanodollars),
                detail: "\(aggregate.coverage.pricedEvents) of \(aggregate.coverage.completeEvents) events priced"
            )
        }
    }

    private var ratios: some View {
        HStack(alignment: .top, spacing: UsageDesign.Spacing.section) {
            MetricTile(
                title: "Input cache hit",
                value: UsageDashboardFormatting.percent(aggregate.inputCacheHitRate),
                detail: "cache-read ÷ observed input"
            )
            MetricTile(
                title: "Output share",
                value: UsageDashboardFormatting.percent(aggregate.outputShare),
                detail: "out ÷ total"
            )
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
            compositionBar

            ViewThatFits(in: .horizontal) {
                bucketGrid(columnCount: 4)
                bucketGrid(columnCount: 2)
                bucketGrid(columnCount: 1)
            }
        }
    }

    /// One hue at four steps rather than four hues: the buckets are parts of a
    /// whole, not unrelated categories, and a categorical palette here would
    /// compete with the agent colours in the chart above.
    private var compositionBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(buckets) { bucket in
                    Rectangle()
                        .fill(Color.accentColor.opacity(bucket.shade))
                        .frame(width: max(0, geometry.size.width * bucket.fraction(of: total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(UsageDesign.inlineShape)
        }
        .frame(height: 16)
        .animation(.smooth(duration: 0.32), value: aggregate.totalTokens)
        .accessibilityElement()
        .accessibilityLabel("Token composition")
        .accessibilityValue(
            buckets
                .map { "\($0.title) \(UsageDashboardFormatting.percent($0.fraction(of: total)))" }
                .joined(separator: ", ")
        )
    }

    private func bucketGrid(columnCount: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 150), spacing: UsageDesign.Spacing.large, alignment: .top),
                count: columnCount
            ),
            alignment: .leading,
            spacing: UsageDesign.Spacing.medium
        ) {
            ForEach(buckets) { bucket in
                HStack(alignment: .top, spacing: UsageDesign.Spacing.small) {
                    // The swatch is what ties a number to its band in the bar.
                    UsageDesign.inlineShape
                        .fill(Color.accentColor.opacity(bucket.shade))
                        .frame(width: 10, height: 10)
                        .padding(.top, 3)

                    MetricTile(
                        title: bucket.title,
                        value: UsageDashboardFormatting.tokens(bucket.tokens),
                        detail: bucket.detail
                    )
                }
            }
        }
        .frame(minWidth: CGFloat(columnCount) * 150)
    }

    private var total: Int64 {
        aggregate.totalTokens
    }

    private var buckets: [Bucket] {
        [
            Bucket(
                id: "in",
                title: "In",
                tokens: aggregate.inputTokens,
                detail: "uncached input",
                shade: 1
            ),
            Bucket(
                id: "cache-write",
                title: "Cache write",
                tokens: aggregate.cacheWriteTokens,
                detail: "new cached input",
                shade: 0.74
            ),
            Bucket(
                id: "cache-read",
                title: "Cache read",
                tokens: aggregate.cacheReadTokens,
                detail: "served from cache",
                shade: 0.48
            ),
            Bucket(
                id: "out",
                title: "Out",
                tokens: aggregate.outputTokens,
                detail: aggregate.reasoningOutputTokens > 0
                    ? "includes \(UsageDashboardFormatting.tokens(aggregate.reasoningOutputTokens)) reasoning"
                    : "billed output",
                shade: 0.26
            ),
        ]
    }

    struct Bucket: Identifiable {
        let id: String
        let title: String
        let tokens: Int64
        let detail: String
        let shade: Double

        func fraction(of total: Int64) -> Double {
            guard total > 0 else { return 0 }
            return Double(tokens) / Double(total)
        }
    }
}
