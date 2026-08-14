import Charts
import SwiftUI

struct UsageDailyChart: View {
    private static let lineWidth: CGFloat = 2.5

    let aggregate: UsageAggregate
    let range: UsageDateRange
    @Binding var metric: UsageChartMetric
    let enabledAgents: Set<UsageAgent>

    @State private var rawSelectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(chartTitle)
                    .font(.headline)

                Spacer()

                // Stays beside the chart: this picks a view of the loaded
                // result, unlike the period and agent controls in the toolbar,
                // which change what gets loaded.
                Picker("Chart metric", selection: $metric) {
                    ForEach(UsageChartMetric.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                legend
            }

            if visibleAgents.isEmpty {
                ContentUnavailableView(
                    metric == .cost ? "No priced cost in this period" : "No token usage in this period",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        enabledAgents.count < UsageAgent.allCases.count
                            ? "Some agents are hidden. Show more from Agents in the toolbar."
                            : "Nothing was recorded for the selected period."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 290)
            } else {
                chart
            }

            if metric == .cost, aggregate.coverage.unpricedCompleteEvents > 0 {
                Label(
                    "Cost series exclude \(aggregate.coverage.unpricedCompleteEvents) complete unpriced event\(aggregate.coverage.unpricedCompleteEvents == 1 ? "" : "s").",
                    systemImage: "asterisk"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Overlaid from a shared zero baseline, each series a solid line over a
    /// faint wash.
    ///
    /// Two passes on purpose: every area first, then every line. Interleaving
    /// them lets a later agent's fill cover an earlier agent's line, and the
    /// line is the channel that identifies the series — the fill is atmosphere,
    /// which is what makes overlapping safe here.
    private var chart: some View {
        Chart {
            ForEach(visibleAgents, id: \.self) { agent in
                areaBand(for: agent)
            }

            ForEach(visibleAgents, id: \.self) { agent in
                lineBand(for: agent)
            }

            selectionMark
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $rawSelectedDate)
        .chartXScale(domain: aggregate.interval.start...chartEnd)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            if range == .oneDay {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisTick().foregroundStyle(.tertiary)
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                        .foregroundStyle(.secondary)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisTick().foregroundStyle(.tertiary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(axisLabel(amount))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 290)
        .animation(.smooth(duration: 0.3), value: metric)
        .animation(.smooth(duration: 0.3), value: enabledAgents)
    }

    /// Reads as a key, not as a control: filtering lives in the toolbar, so
    /// these carry no press state and nothing here is clickable.
    private var legend: some View {
        HStack(spacing: UsageDesign.Spacing.medium) {
            ForEach(visibleAgents, id: \.self) { agent in
                HStack(spacing: UsageDesign.Spacing.tight + 2) {
                    UsageAgentIconView(agent: agent, size: 13)
                    Text(agent.displayName)
                        .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Series: \(visibleAgents.map(\.displayName).joined(separator: ", "))")
    }

    /// `AnnotationOverflowResolution` clamps the callout inside the plot area,
    /// which replaced hand-measured tooltip geometry against a fixed 160×68 box.
    @ChartContentBuilder
    private var selectionMark: some ChartContent {
        if let snapshot {
            // `lineStyle` before `foregroundStyle`: on macOS 26 `RuleMark`
            // conforms to both `ChartContent` and `Chart3DContent`, and
            // `foregroundStyle` exists on both, so leading with it resolves the
            // chain to the 3D overload. `lineStyle` is 2D-only and pins it.
            RuleMark(x: .value("Selected time", snapshot.date))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
                .annotation(
                    position: .top,
                    spacing: UsageDesign.Spacing.small,
                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                    callout(snapshot)
                }
        }
    }

    /// Explicit `yStart`/`yEnd` with a `series:` key, which is what keeps the
    /// areas independent instead of letting Swift Charts stack them.
    @ChartContentBuilder
    private func areaBand(for agent: UsageAgent) -> some ChartContent {
        ForEach(curve(for: agent)) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Baseline", 0.0),
                yEnd: .value(metric.label, point.value),
                series: .value("Agent", agent.displayName)
            )
            .foregroundStyle(agent.chartFill)
            .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private func lineBand(for agent: UsageAgent) -> some ChartContent {
        ForEach(curve(for: agent)) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value(metric.label, point.value),
                series: .value("Agent", agent.displayName)
            )
            .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(agent.chartColor)
            .interpolationMethod(.linear)
            .accessibilityLabel(accessibilityLabel(for: agent, at: point.date))
            .accessibilityValue(axisLabel(point.value))
        }
    }

    private func accessibilityLabel(for agent: UsageAgent, at date: Date) -> String {
        "\(agent.displayName), \(timestampText(date))"
    }

    /// Every visible series at the selected instant, plus their total. A stacked
    /// chart is read across the stack, so the callout reports the whole column
    /// rather than the one series the pointer happened to land on.
    private func callout(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
            Text(timestampText(snapshot.date))
                .font(.caption.weight(.semibold))

            ForEach(snapshot.entries, id: \.agent) { entry in
                HStack(spacing: UsageDesign.Spacing.small) {
                    Circle()
                        .fill(entry.agent.chartColor)
                        .frame(width: 7, height: 7)
                    Text(entry.agent.displayName)
                        .font(.caption)
                    Spacer(minLength: UsageDesign.Spacing.medium)
                    Text(axisLabel(entry.value))
                        .font(.caption.monospacedDigit())
                }
            }

            if snapshot.entries.count > 1 {
                Divider()
                HStack(spacing: UsageDesign.Spacing.small) {
                    Text("Total")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: UsageDesign.Spacing.medium)
                    Text(axisLabel(snapshot.total))
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, UsageDesign.Spacing.medium)
        .padding(.vertical, UsageDesign.Spacing.small)
        .background(.regularMaterial, in: UsageDesign.inlineShape)
        .overlay(UsageDesign.inlineShape.stroke(.separator))
    }

    private struct Snapshot {
        let date: Date
        let entries: [(agent: UsageAgent, value: Double)]

        var total: Double { entries.reduce(0) { $0 + $1.value } }
    }

    private var snapshot: Snapshot? {
        guard
            let rawSelectedDate,
            let date = UsageChartInteraction.nearestDate(to: rawSelectedDate, in: gridDates)
        else {
            return nil
        }

        let entries = visibleAgents.compactMap { agent -> (agent: UsageAgent, value: Double)? in
            guard let point = curve(for: agent).first(where: { $0.date == date }), point.value > 0 else {
                return nil
            }
            return (agent, point.value)
        }

        return entries.isEmpty ? nil : Snapshot(date: date, entries: entries)
    }

    private var visibleAgents: [UsageAgent] {
        UsageDashboardPresentation.chartAgents(from: aggregate, metric: metric)
            .filter { enabledAgents.contains($0) }
    }

    /// Densified onto a shared grid, then smoothed. Both series get the same
    /// sample dates, which is what lets Swift Charts stack them.
    private var curves: [UsageAgent: [UsageChartCurvePoint]] {
        let raw = Dictionary(
            uniqueKeysWithValues: visibleAgents.map { agent in
                (
                    agent,
                    aggregate.chartPoints
                        .filter { $0.agent == agent }
                        .map { UsageChartCurvePoint(date: $0.timestamp, value: value(for: $0)) }
                        .sorted { $0.date < $1.date }
                )
            }
        )
        return UsageChartInteraction.densified(series: raw)
            .mapValues { UsageChartCurve.samples(points: $0) }
    }

    private func curve(for agent: UsageAgent) -> [UsageChartCurvePoint] {
        curves[agent] ?? []
    }

    private var gridDates: [Date] {
        curves.values.first.map { $0.map(\.date) } ?? []
    }

    private var chartTitle: String {
        let prefix = range == .oneDay ? "Hourly" : "Daily"
        return "\(prefix) \(metric == .cost ? "cost" : "tokens")"
    }

    private var chartEnd: Date {
        max(aggregate.interval.start.addingTimeInterval(1), aggregate.interval.end.addingTimeInterval(-1))
    }

    private func value(for point: UsageChartPoint) -> Double {
        switch metric {
        case .cost:
            Double(point.estimatedCostNanodollars) / 1_000_000_000
        case .tokens:
            Double(point.totalTokens)
        }
    }

    private func timestampText(_ date: Date) -> String {
        range == .oneDay
            ? UsageDashboardFormatting.dateAndTime(date)
            : UsageDashboardFormatting.date(date)
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .cost:
            return UsageDashboardFormatting.currency(
                nanodollars: Int64((value * 1_000_000_000).rounded()),
                compact: true
            )
        case .tokens:
            return UsageDashboardFormatting.tokens(Int64(value.rounded()))
        }
    }
}
