import SwiftUI

struct UsageDashboardView: View {
    @StateObject private var model: UsageDashboardModel
    @SceneStorage("usageDashboard.range") private var rangeRawValue = UsageDateRange.sevenDays.rawValue
    @SceneStorage("usageDashboard.chartMetric") private var chartMetricRawValue = UsageChartMetric.cost.rawValue
    @SceneStorage("usageDashboard.breakdown") private var breakdownRawValue = UsageBreakdownMode.model.rawValue
    @SceneStorage("usageDashboard.agents") private var enabledAgentRawValue = UsageAgent.allCases
        .map(\.rawValue)
        .joined(separator: ",")

    @State private var showsImportIssues = false

    private let runsInitialLoad: Bool

    @MainActor
    init() {
        _model = StateObject(wrappedValue: .live())
        runsInitialLoad = true
    }

    @MainActor
    init(model: UsageDashboardModel, runsInitialLoad: Bool) {
        _model = StateObject(wrappedValue: model)
        self.runsInitialLoad = runsInitialLoad
    }

    var body: some View {
        Group {
            if let aggregate = model.aggregate {
                dashboard(aggregate)
            } else if model.isRefreshing || model.isLoadingAggregate {
                ProgressView(model.isRefreshing ? "Importing local usage…" : "Loading usage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableState
            }
        }
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Period and agents both scope the query that runs against the
                // store, so they sit together here. Metric and grouping choose a
                // view of the result and stay beside the things they change.
                Picker("Tracking period", selection: $rangeRawValue) {
                    ForEach(UsageDateRange.allCases, id: \.self) { range in
                        Text(range.shortLabel).tag(range.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Tracking period")

                agentFilterMenu

                Button {
                    Task {
                        await model.refresh(range: selectedRange, agents: enabledAgents)
                    }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh usage", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing || !model.canRefresh)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            guard runsInitialLoad else { return }
            await model.loadInitially(range: selectedRange, agents: enabledAgents)
        }
        .onChange(of: rangeRawValue) {
            reloadForFilterChange()
        }
        .onChange(of: enabledAgentRawValue) {
            reloadForFilterChange()
        }
    }

    private func dashboard(_ aggregate: UsageAggregate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.section) {
                if let errorMessage = model.errorMessage {
                    statusBanner(errorMessage, systemImage: "exclamationmark.triangle")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: UsageDesign.Spacing.section + UsageDesign.Spacing.small) {
                        UsageCostSummary(aggregate: aggregate)
                            .frame(width: 310)
                        dailyChart(aggregate)
                            .frame(minWidth: 470)
                    }

                    VStack(alignment: .leading, spacing: UsageDesign.Spacing.section) {
                        UsageCostSummary(aggregate: aggregate)
                        dailyChart(aggregate)
                    }
                }

                UsageMetricStrip(aggregate: aggregate)

                if aggregate.coverage.totalEvents == 0 {
                    ContentUnavailableView(
                        "No usage in this period",
                        systemImage: "chart.xyaxis.line",
                        description: Text("BorderCollie searched local Claude Code, Codex, OpenCode, and Pi histories. Try another period or refresh the index.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    UsageBreakdownTable(aggregate: aggregate, mode: breakdownBinding)
                }

                coverageFooter(aggregate)
            }
            .padding(UsageDesign.Spacing.section)
            .frame(maxWidth: 1_500, alignment: .topLeading)
        }
    }

    private func dailyChart(_ aggregate: UsageAggregate) -> some View {
        UsageDailyChart(
            aggregate: aggregate,
            range: selectedRange,
            metric: chartMetricBinding,
            enabledAgents: enabledAgents
        )
    }

    /// The agent filter used to be the chart's legend: eight-point dots with a
    /// 0.35-opacity off state, no hover, no focus ring, and no hint that a click
    /// re-runs the query. It is a scope control, so it lives with the other one.
    private var agentFilterMenu: some View {
        Menu {
            ForEach(UsageAgent.dashboardOrder, id: \.self) { agent in
                Toggle(isOn: binding(for: agent)) {
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        UsageAgentIconView(agent: agent, size: 14, isTinted: false)
                    }
                }
            }

            Divider()

            Button("Show All Agents") {
                enabledAgentsBinding.wrappedValue = Set(UsageAgent.allCases)
            }
            .disabled(enabledAgents.count == UsageAgent.allCases.count)
        } label: {
            Label(
                "Agents",
                systemImage: isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help(isFiltered ? "Showing \(enabledAgents.count) of \(UsageAgent.allCases.count) agents" : "Filter agents")
    }

    private var isFiltered: Bool {
        enabledAgents.count < UsageAgent.allCases.count
    }

    private func binding(for agent: UsageAgent) -> Binding<Bool> {
        Binding(
            get: { enabledAgents.contains(agent) },
            set: { isEnabled in
                var agents = enabledAgents
                if isEnabled {
                    agents.insert(agent)
                } else {
                    agents.remove(agent)
                }
                enabledAgentsBinding.wrappedValue = agents
            }
        )
    }

    @ViewBuilder
    private var unavailableState: some View {
        if let errorMessage = model.errorMessage {
            ContentUnavailableView(
                "Usage unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            ContentUnavailableView(
                "No usage loaded",
                systemImage: "chart.xyaxis.line",
                description: Text("Refresh to index local Claude Code, Codex, OpenCode, and Pi histories.")
            )
        }
    }

    /// Coverage caveats qualify the numbers above, so they stay here. Import
    /// failures do not — they are about the index, they were being truncated at
    /// four with no way to reach the rest, and at caption weight an
    /// `xmark.octagon` read the same as a timestamp. They moved to the button.
    private func coverageFooter(_ aggregate: UsageAggregate) -> some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
            if !model.importIssues.isEmpty {
                importIssuesButton
            }

            VStack(alignment: .leading, spacing: 7) {
                if aggregate.coverage.partialEvents > 0 {
                    Label(
                        "\(aggregate.coverage.partialEvents) partial event\(aggregate.coverage.partialEvents == 1 ? " was" : "s were") excluded from token and cost totals.",
                        systemImage: "exclamationmark.circle"
                    )
                }
                if aggregate.coverage.unpricedCompleteEvents > 0 {
                    Label(
                        "\(aggregate.coverage.unpricedCompleteEvents) complete event\(aggregate.coverage.unpricedCompleteEvents == 1 ? " has" : "s have") no verified public price; token totals include them and cost totals do not.",
                        systemImage: "dollarsign.circle"
                    )
                }
                if let updated = model.lastSuccessfulImport {
                    Text("Last imported at \(updated, style: .time)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private var importIssuesButton: some View {
        Button {
            showsImportIssues = true
        } label: {
            Label(
                "\(model.importIssues.count) import issue\(model.importIssues.count == 1 ? "" : "s")",
                systemImage: hasImportError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(hasImportError ? .red : .orange)
        }
        .buttonStyle(.link)
        .popover(isPresented: $showsImportIssues, arrowEdge: .bottom) {
            importIssuesList
        }
    }

    private var importIssuesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
                Text("Import issues")
                    .font(.headline)

                ForEach(Array(model.importIssues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.agent.displayName)
                                .font(.callout.weight(.medium))
                            Text(issue.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }

                Text("Each agent imports independently, so the other agents' history is still up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(UsageDesign.Spacing.large)
            .frame(width: 380, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }

    private var hasImportError: Bool {
        model.importIssues.contains { $0.severity == .error }
    }

    private func statusBanner(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .symbolRenderingMode(.multicolor)
            .padding(UsageDesign.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: UsageDesign.cardShape)
            .overlay(UsageDesign.cardShape.stroke(.separator))
    }

    private var selectedRange: UsageDateRange {
        UsageDateRange(rawValue: rangeRawValue) ?? .sevenDays
    }

    private var enabledAgents: Set<UsageAgent> {
        Set(enabledAgentRawValue.split(separator: ",").compactMap { UsageAgent(rawValue: String($0)) })
    }

    private var chartMetricBinding: Binding<UsageChartMetric> {
        Binding(
            get: { UsageChartMetric(rawValue: chartMetricRawValue) ?? .cost },
            set: { chartMetricRawValue = $0.rawValue }
        )
    }

    private var breakdownBinding: Binding<UsageBreakdownMode> {
        Binding(
            get: { UsageBreakdownMode(rawValue: breakdownRawValue) ?? .model },
            set: { breakdownRawValue = $0.rawValue }
        )
    }

    private var enabledAgentsBinding: Binding<Set<UsageAgent>> {
        Binding(
            get: { enabledAgents },
            set: { agents in
                enabledAgentRawValue = agents
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.rawValue)
                    .joined(separator: ",")
            }
        )
    }

    private func reloadForFilterChange() {
        guard runsInitialLoad else { return }
        Task {
            await model.loadAggregate(range: selectedRange, agents: enabledAgents)
        }
    }
}

private struct UsageCostSummary: View {
    let aggregate: UsageAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
                // Sentence case and SF Pro at a regular weight: all-caps labels
                // and SF Rounded are iOS-widget vernacular, and neither appears
                // in macOS system UI.
                Text("Estimated API-equivalent token cost")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: UsageDesign.Spacing.small) {
                    Text(costText)
                        .font(.heroValue)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.32), value: aggregate.estimatedCostNanodollars)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if aggregate.coverage.unpricedCompleteEvents > 0 {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help(unpricedExplanation)
                            .accessibilityLabel(unpricedExplanation)
                    }
                }

                Text(
                    aggregate.range == .oneDay
                        ? UsageDashboardFormatting.rollingInterval(aggregate.interval)
                        : UsageDashboardFormatting.interval(aggregate.interval)
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Token-only estimate at public API rates")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
                    HStack(spacing: UsageDesign.Spacing.small) {
                        UsageAgentIconView(agent: summary.agent, size: 17)
                        Text(summary.agent.displayName)
                        Spacer()
                        Text(summaryCostText(summary))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if summary.pricedEvents > 0 {
                        ProgressView(value: costShare(summary))
                            .progressViewStyle(.linear)
                            .tint(summary.agent.chartColor)
                        Text("\(shareText(summary)) of priced cost · \(UsageDashboardFormatting.tokens(summary.totalTokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No verified public price · \(UsageDashboardFormatting.tokens(summary.totalTokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.smooth(duration: 0.32), value: summaries)
    }

    /// The asterisk in the figure explained where the figure is, rather than in
    /// the footer at the bottom of the screen.
    private var unpricedExplanation: String {
        let count = aggregate.coverage.unpricedCompleteEvents
        return "\(count) complete event\(count == 1 ? " has" : "s have") no verified public price. Token totals include them; this cost does not."
    }

    private var summaries: [UsageAgentSummary] {
        UsageDashboardPresentation.agentSummaries(from: aggregate)
    }

    private var costText: String {
        UsageDashboardFormatting.currency(nanodollars: aggregate.estimatedCostNanodollars)
            + (aggregate.coverage.unpricedCompleteEvents > 0 ? "*" : "")
    }

    private func costShare(_ summary: UsageAgentSummary) -> Double {
        guard aggregate.estimatedCostNanodollars > 0 else { return 0 }
        return Double(summary.estimatedCostNanodollars) / Double(aggregate.estimatedCostNanodollars)
    }

    private func summaryCostText(_ summary: UsageAgentSummary) -> String {
        guard summary.pricedEvents > 0 else { return "Unpriced" }
        return UsageDashboardFormatting.currency(nanodollars: summary.estimatedCostNanodollars)
            + (summary.hasPartialPricing ? "*" : "")
    }

    private func shareText(_ summary: UsageAgentSummary) -> String {
        guard aggregate.estimatedCostNanodollars > 0 else { return "—" }
        return UsageDashboardFormatting.percent(costShare(summary))
    }
}

private enum UsageDashboardPreviewData {
    static let aggregate: UsageAggregate = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = Date(timeIntervalSince1970: 1_786_492_800)
        let start = calendar.date(byAdding: .day, value: -7, to: end)!
        let agents = UsageAgent.allCases
        let values: [UsageAgent: [Int64]] = [
            .claudeCode: [12_000_000, 18_000_000, 9_000_000, 22_000_000, 31_000_000, 26_000_000, 48_000_000],
            .codex: [7_000_000, 11_000_000, 15_000_000, 13_000_000, 19_000_000, 38_000_000, 29_000_000],
            .openCode: [2_000_000, 4_000_000, 1_000_000, 6_000_000, 3_000_000, 8_000_000, 5_000_000],
            .pi: [1_000_000, 2_000_000, 3_000_000, 2_000_000, 5_000_000, 4_000_000, 7_000_000],
        ]
        var daily: [UsageDailyPoint] = []
        var models: [UsageModelBreakdown] = []
        for agent in agents {
            let agentValues = values[agent]!
            for (index, tokens) in agentValues.enumerated() {
                let input = tokens / 5
                let cacheWrite = tokens / 10
                let cacheRead = tokens / 2
                let output = tokens - input - cacheWrite - cacheRead
                daily.append(UsageDailyPoint(
                    day: calendar.date(byAdding: .day, value: index, to: start)!,
                    agent: agent,
                    inputTokens: input,
                    cacheWriteTokens: cacheWrite,
                    cacheReadTokens: cacheRead,
                    outputTokens: output,
                    reasoningOutputTokens: tokens / 20,
                    totalTokens: tokens,
                    estimatedCostNanodollars: tokens * Int64(index + 4),
                    completeEvents: 3,
                    pricedEvents: agent == .openCode ? 2 : 3
                ))
            }
            let agentDaily = daily.filter { $0.agent == agent }
            models.append(UsageModelBreakdown(
                agent: agent,
                modelID: previewModel(for: agent),
                inputTokens: agentDaily.reduce(0) { $0 + $1.inputTokens },
                cacheWriteTokens: agentDaily.reduce(0) { $0 + $1.cacheWriteTokens },
                cacheReadTokens: agentDaily.reduce(0) { $0 + $1.cacheReadTokens },
                outputTokens: agentDaily.reduce(0) { $0 + $1.outputTokens },
                reasoningOutputTokens: agentDaily.reduce(0) { $0 + $1.reasoningOutputTokens },
                totalTokens: agentValues.reduce(0, +),
                estimatedCostNanodollars: agentValues.enumerated().reduce(0) { $0 + $1.element * Int64($1.offset + 4) },
                completeEvents: 21,
                pricedEvents: agent == .openCode ? 14 : 21
            ))
        }
        let total = models.reduce(0) { $0 + $1.totalTokens }
        let cost = models.reduce(0) { $0 + $1.estimatedCostNanodollars }
        return UsageAggregate(
            range: .sevenDays,
            interval: DateInterval(start: start, end: end),
            agents: Set(agents),
            inputTokens: total / 5,
            cacheWriteTokens: total / 10,
            cacheReadTokens: total / 2,
            outputTokens: total - (total / 5 + total / 10 + total / 2),
            reasoningOutputTokens: total / 20,
            totalTokens: total,
            estimatedCostNanodollars: cost,
            inputCacheHitRate: 0.625,
            outputShare: 0.2,
            chartPoints: daily.map { point in
                UsageChartPoint(
                    timestamp: point.day,
                    agent: point.agent,
                    totalTokens: point.totalTokens,
                    estimatedCostNanodollars: point.estimatedCostNanodollars,
                    completeEvents: point.completeEvents,
                    pricedEvents: point.pricedEvents
                )
            },
            daily: daily,
            models: models,
            coverage: UsageCoverage(
                totalEvents: 84,
                completeEvents: 84,
                pricedEvents: 77,
                partialEvents: 0,
                unpricedCompleteEvents: 7
            )
        )
    }()

    private static func previewModel(for agent: UsageAgent) -> String {
        switch agent {
        case .claudeCode: "claude-sonnet-5"
        case .codex: "gpt-5.6-sol"
        case .openCode: "gateway-model"
        case .pi: "gpt-5.6-terra"
        }
    }
}

struct UsageDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            UsageDashboardView(
                model: .preview(aggregate: UsageDashboardPreviewData.aggregate),
                runsInitialLoad: false
            )
        }
        .frame(width: 1_200, height: 850)
        .previewDisplayName("Historical usage dashboard")
    }
}
