import Charts
import SwiftUI

struct UsageDailyChart: View {
    let aggregate: UsageAggregate
    let range: UsageDateRange
    @Binding var metric: UsageChartMetric
    @Binding var enabledAgents: Set<UsageAgent>
    @State private var hoverSelection: UsageChartHoverSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(chartTitle)
                    .font(.headline)

                Spacer()

                Picker("Chart metric", selection: $metric) {
                    ForEach(UsageChartMetric.allCases) { option in
                        Text(option.label.uppercased()).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if !chartAgents.isEmpty {
                agentLegend
            }

            if chartAgents.isEmpty {
                ContentUnavailableView(
                    metric == .cost ? "No priced cost in this period" : "No token usage in this period",
                    systemImage: "chart.xyaxis.line"
                )
                .frame(maxWidth: .infinity, minHeight: 290)
            } else {
                Chart {
                    ForEach(chartAgents, id: \.self) { agent in
                        if enabledAgents.contains(agent) {
                            ForEach(points(for: agent)) { point in
                                AreaMark(
                                    x: .value("Time", point.timestamp),
                                    yStart: .value("Baseline", 0.0),
                                    yEnd: .value(metric.label, value(for: point)),
                                    series: .value("Agent", agent.displayName)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [agent.chartColor.opacity(0.22), agent.chartColor.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .interpolationMethod(.monotone)

                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value(metric.label, value(for: point)),
                                    series: .value("Agent", agent.displayName)
                                )
                                .foregroundStyle(agent.chartColor)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                                .accessibilityLabel(
                                    "\(agent.displayName), \(timestampText(point.timestamp)), \(metric.label.lowercased())"
                                )
                                .accessibilityValue(accessibilityValue(for: point))
                            }
                        }
                    }

                    if let hoverSelection {
                        RuleMark(x: .value("Selected time", hoverSelection.date))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .lineStyle(hoverGuideStyle)

                        RuleMark(y: .value(metric.label, hoverSelection.value))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .lineStyle(hoverGuideStyle)

                        PointMark(
                            x: .value("Selected time", hoverSelection.date),
                            y: .value(metric.label, hoverSelection.value)
                        )
                        .foregroundStyle(hoverSelection.agent.chartColor)
                        .symbolSize(55)
                        .annotation(position: .top, spacing: 8) {
                            hoverAnnotation(for: hoverSelection)
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: aggregate.interval.start...chartEnd)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    if range == .oneDay {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine().foregroundStyle(.clear)
                            AxisTick().foregroundStyle(.tertiary)
                            AxisValueLabel(
                                format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))
                            )
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(.clear)
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
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateHover(phase, proxy: proxy, geometry: geometry)
                            }
                    }
                }
                .frame(minHeight: 290)
                .onChange(of: metric) {
                    hoverSelection = nil
                }
                .onChange(of: enabledAgents) {
                    hoverSelection = nil
                }
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

    private var agentLegend: some View {
        HStack(spacing: 16) {
            ForEach(chartAgents, id: \.self) { agent in
                Button {
                    toggle(agent)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agent.chartColor)
                            .frame(width: 8, height: 8)
                        Text(agent.displayName)
                            .font(.caption)
                    }
                    .opacity(enabledAgents.contains(agent) ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(agent.displayName) chart series")
                .accessibilityValue(enabledAgents.contains(agent) ? "Shown" : "Hidden")
            }
        }
    }

    private var chartAgents: [UsageAgent] {
        UsageDashboardPresentation.chartAgents(from: aggregate, metric: metric)
    }

    private var chartTitle: String {
        let prefix = range == .oneDay ? "Hourly" : "Daily"
        return "\(prefix) \(metric == .cost ? "cost" : "tokens")"
    }

    private func points(for agent: UsageAgent) -> [UsageChartPoint] {
        aggregate.chartPoints.filter { $0.agent == agent }
    }

    private var chartEnd: Date {
        max(aggregate.interval.start.addingTimeInterval(1), aggregate.interval.end.addingTimeInterval(-1))
    }

    private var hoverGuideStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1, dash: [5, 4])
    }

    private func toggle(_ agent: UsageAgent) {
        if enabledAgents.contains(agent) {
            enabledAgents.remove(agent)
        } else {
            enabledAgents.insert(agent)
        }
    }

    private func value(for point: UsageChartPoint) -> Double {
        switch metric {
        case .cost:
            Double(point.estimatedCostNanodollars) / 1_000_000_000
        case .tokens:
            Double(point.totalTokens)
        }
    }

    private func updateHover(_ phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) {
        guard case let .active(location) = phase,
              let plotFrameAnchor = proxy.plotFrame
        else {
            hoverSelection = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoverSelection = nil
            return
        }

        let pointer = CGPoint(x: location.x - plotFrame.minX, y: location.y - plotFrame.minY)
        let series = chartAgents.compactMap { agent -> UsageChartScreenSeries? in
            guard enabledAgents.contains(agent) else { return nil }
            let screenPoints = points(for: agent).compactMap { point -> UsageChartScreenPoint? in
                guard let position = proxy.position(for: (x: point.timestamp, y: value(for: point))) else {
                    return nil
                }
                return UsageChartScreenPoint(date: point.timestamp, value: value(for: point), position: position)
            }
            guard !screenPoints.isEmpty else { return nil }
            return UsageChartScreenSeries(agent: agent, points: screenPoints)
        }

        hoverSelection = UsageChartInteraction.nearestSelection(
            to: pointer,
            series: series,
            maximumDistance: 14
        )
    }

    private func hoverAnnotation(for selection: UsageChartHoverSelection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selection.agent.displayName)
                .font(.caption.weight(.semibold))
            Text(timestampText(selection.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(axisLabel(selection.value))
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func accessibilityValue(for point: UsageChartPoint) -> String {
        switch metric {
        case .cost:
            let suffix = point.pricedEvents < point.completeEvents ? ", partial pricing coverage" : ""
            return UsageDashboardFormatting.currency(nanodollars: point.estimatedCostNanodollars) + suffix
        case .tokens:
            return "\(point.totalTokens.formatted()) tokens"
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
