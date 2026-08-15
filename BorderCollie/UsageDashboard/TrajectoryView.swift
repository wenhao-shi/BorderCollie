import SwiftUI

struct TrajectoryView: View {
    @StateObject private var model: TrajectoryModel
    @SceneStorage("trajectory.period") private var periodRaw = TrajectoryPeriod.last30Days.rawValue
    @SceneStorage("trajectory.agents") private var agentsRaw = UsageAgent.allCases.map(\.rawValue).joined(separator: ",")
    @SceneStorage("trajectory.timeMode") private var modeRaw = TrajectoryTimeMode.order.rawValue
    @State private var searchText = ""
    @State private var collapsedRecordIDs: Set<String> = []
    @State private var rangeSelectedRecordIDs: Set<String> = []

    @MainActor
    init() {
        _model = StateObject(wrappedValue: .live())
    }

    @MainActor
    init(model: TrajectoryModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        HSplitView {
            sessionList
                .frame(idealWidth: 280, maxWidth: 360)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Trajectory")
        .navigationSubtitle(model.selectedSessionKey.map { "Session \(abbreviated($0))" } ?? "One indexed session")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Period", selection: $periodRaw) {
                    ForEach(TrajectoryPeriod.allCases, id: \.rawValue) { period in
                        Text(period.label).tag(period.rawValue)
                    }
                }
                .pickerStyle(.menu)

                agentFilter

                Picker("Timeline", selection: $modeRaw) {
                    ForEach(TrajectoryTimeMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    Task { await refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh trajectory", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!model.canRefresh || model.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await model.loadInitially(period: period, agents: agents)
            if model.selectedSessionKey == nil, let first = model.sessions.first {
                await model.selectSession(first.sessionKey)
            }
        }
        .onChange(of: periodRaw) {
            Task { await reloadSessions() }
        }
        .onChange(of: agentsRaw) {
            Task { await reloadSessions() }
        }
        .onChange(of: modeRaw) {
            collapsedRecordIDs = []
            rangeSelectedRecordIDs = []
        }
        .onExitCommand {
            rangeSelectedRecordIDs = []
            model.selectRecord(nil)
        }
    }

    private var sessionList: some View {
        List(selection: selectedSessionBinding) {
            if model.sessions.isEmpty && model.isLoading {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No indexed sessions",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Refresh after a supported agent has written local history.")
                )
            } else {
                ForEach(model.sessions) { session in
                    TrajectorySessionRow(session: session)
                        .tag(session.sessionKey)
                }
                if model.hasMoreSessions {
                    Button("Load earlier") {
                        Task { await model.loadEarlier(period: period, agents: agents) }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .buttonStyle(.link)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let report = model.report {
            TrajectoryDetailView(
                report: report,
                projection: model.projection(mode: mode, collapsedRecordIDs: collapsedRecordIDs)
                    ?? TrajectoryProjection.make(report: report, mode: mode, collapsedRecordIDs: collapsedRecordIDs),
                mode: mode,
                searchText: searchText,
                selectedRecordID: model.selectedRecordID,
                rangeSelectedRecordIDs: rangeSelectedRecordIDs,
                collapsedRecordIDs: $collapsedRecordIDs,
                onSelect: {
                    rangeSelectedRecordIDs = []
                    model.selectRecord($0)
                },
                onRangeSelect: {
                    rangeSelectedRecordIDs = $0
                    model.selectRecord(
                        projectionRecordID(
                            firstIn: $0,
                            projection: model.projection(mode: mode, collapsedRecordIDs: collapsedRecordIDs)
                        )
                    )
                },
                onSearchChange: { searchText = $0 }
            )
            .overlay(alignment: .top) {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(UsageDesign.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                }
            }
        } else if model.isLoading {
            ProgressView("Loading trajectory…")
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView(
                "Trajectory unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            ContentUnavailableView(
                "Select a session",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Choose an indexed session to inspect its source-backed timing and capability coverage.")
            )
        }
    }

    private var agentFilter: some View {
        Menu {
            ForEach(UsageAgent.allCases, id: \.rawValue) { agent in
                Toggle(
                    agent.displayName,
                    isOn: Binding(
                        get: { agents.contains(agent) },
                        set: { enabled in
                            var updated = agents
                            if enabled { updated.insert(agent) } else { updated.remove(agent) }
                            agentsRaw = updated.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ",")
                        }
                    )
                )
            }
        } label: {
            Label("Agents", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var selectedSessionBinding: Binding<String?> {
        Binding(
            get: { model.selectedSessionKey },
            set: { key in
                rangeSelectedRecordIDs = []
                Task { await model.selectSession(key) }
            }
        )
    }

    private var period: TrajectoryPeriod {
        TrajectoryPeriod(rawValue: periodRaw) ?? .last30Days
    }

    private var mode: TrajectoryTimeMode {
        TrajectoryTimeMode(rawValue: modeRaw) ?? .order
    }

    private var agents: Set<UsageAgent> {
        let parsed = Set(
            agentsRaw.split(separator: ",").compactMap { UsageAgent(rawValue: String($0)) }
        )
        return parsed.isEmpty ? Set(UsageAgent.allCases) : parsed
    }

    private func refresh() async {
        await model.refresh(period: period, agents: agents)
        if model.selectedSessionKey == nil, let first = model.sessions.first {
            await model.selectSession(first.sessionKey)
        }
    }

    private func reloadSessions() async {
        rangeSelectedRecordIDs = []
        await model.loadPage(period: period, agents: agents, replacing: true)
        if let selected = model.selectedSessionKey, model.sessions.contains(where: { $0.sessionKey == selected }) {
            await model.selectSession(selected)
        } else if let first = model.sessions.first {
            await model.selectSession(first.sessionKey)
        }
    }

    private func abbreviated(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func projectionRecordID(
        firstIn ids: Set<String>,
        projection: TrajectoryProjectionResult?
    ) -> String? {
        projection?.records
            .filter { ids.contains($0.id) }
            .min { $0.canonicalOrder < $1.canonicalOrder }?
            .id
    }
}

private struct TrajectorySessionRow: View {
    let session: TrajectorySessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
            HStack(spacing: UsageDesign.Spacing.small) {
                UsageAgentIconView(agent: session.agent, size: 16)
                Text(session.agent.displayName)
                    .fontWeight(.medium)
                Spacer()
                Text(String(session.sessionKey.prefix(8)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(UsageDashboardFormatting.dateAndTime(date(session.startedAtMilliseconds)))
                .font(.caption)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, UsageDesign.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.agent.displayName) session")
        .accessibilityValue(detail)
    }

    private var detail: String {
        let counts = "\(session.turnCount) turns · \(session.activityCount) activities · \(session.usageEventCount) usage events"
        guard !session.modelIDs.isEmpty else { return counts }
        return "\(session.modelIDs.joined(separator: ", ")) · \(counts)"
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

private struct TrajectoryDetailView: View {
    let report: TrajectorySessionReport
    let projection: TrajectoryProjectionResult
    let mode: TrajectoryTimeMode
    let searchText: String
    let selectedRecordID: String?
    let rangeSelectedRecordIDs: Set<String>
    @Binding var collapsedRecordIDs: Set<String>
    let onSelect: (String?) -> Void
    let onRangeSelect: (Set<String>) -> Void
    let onSearchChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
            metadataHeader
            TrajectoryTimelineView(
                report: report,
                projection: projection,
                mode: mode,
                selectedRecordID: selectedRecordID,
                rangeSelectedRecordIDs: rangeSelectedRecordIDs,
                onSelect: onSelect,
                onRangeSelect: onRangeSelect
            )
            .frame(minHeight: 190, maxHeight: 250)

            HSplitView {
                TrajectoryLedgerView(
                    report: report,
                    projection: projection,
                    searchText: searchText,
                    selectedRecordID: selectedRecordID,
                    rangeSelectedRecordIDs: rangeSelectedRecordIDs,
                    collapsedRecordIDs: $collapsedRecordIDs,
                    onSelect: onSelect,
                    onRangeSelect: onRangeSelect,
                    onSearchChange: onSearchChange
                )
                .frame(maxWidth: .infinity)
                TrajectoryInspectorView(
                    report: report,
                    selectedRecordID: selectedRecordID,
                    onClose: { onSelect(nil) }
                )
                .frame(idealWidth: 310, maxWidth: 380)
            }
        }
        .padding(UsageDesign.Spacing.large)
    }

    private var metadataHeader: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
                HStack {
                    UsageAgentIconView(agent: report.summary.agent, size: 22)
                    Text(report.summary.agent.displayName)
                        .font(.headline)
                    Text(String(report.summary.sessionKey.prefix(12)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.summary.turnCount) turns · \(report.summary.activityCount) activities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(date(report.summary.startedAtMilliseconds)) – \(date(report.summary.endedAtMilliseconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                capabilitySummary
            }
        } label: {
            Text("Session metadata")
                .font(.headline)
        }
    }

    private var capabilitySummary: some View {
        HStack(spacing: UsageDesign.Spacing.small) {
            ForEach(TrajectoryCapabilityFamily.allCases, id: \.rawValue) { family in
                let rows = report.capabilities.filter { $0.family == family }
                let availability = rows.first?.availability
                Text("\(family.label): \(availability?.label ?? "Unavailable")")
                    .font(.caption2)
                    .foregroundStyle(availability == .unavailable ? .secondary : .primary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trajectory capability coverage")
    }

    private func date(_ milliseconds: Int64) -> String {
        UsageDashboardFormatting.dateAndTime(Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
    }
}

private extension TrajectoryPeriod {
    var label: String {
        switch self {
        case .last24Hours: "24 hours"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .all: "All"
        }
    }
}

private extension TrajectoryTimeMode {
    var label: String {
        switch self {
        case .order: "Order"
        case .activeTime: "Active time"
        case .clockTime: "Clock time"
        }
    }
}

private extension TrajectoryCapabilityFamily {
    var label: String {
        switch self {
        case .turnTiming: "Turns"
        case .modelTiming: "Models"
        case .firstOutputTiming: "First output"
        case .tools: "Tools"
        case .toolNesting: "Nesting"
        case .retries: "Retries"
        case .compaction: "Compaction"
        }
    }
}

private extension TrajectoryCapabilityAvailability {
    var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .partial: "Partial"
        case .complete: "Complete"
        }
    }
}

private enum TrajectoryPreviewData {
    static let report: TrajectorySessionReport = {
        let turn = try! UsageActiveTurn.normalized(
            agent: .codex,
            sessionKey: "preview-session",
            pricingAuthority: .openAI,
            rawModelID: "preview-model",
            canonicalModelID: "preview-model",
            startedAtMilliseconds: 1_785_600_000_000,
            endedAtMilliseconds: 1_785_600_012_000,
            timingQuality: .exact,
            sourceKey: "preview-source",
            sourceID: "preview-turn",
            importerVersion: 3
        )
        let capabilities = TrajectoryCapabilityFamily.allCases.map { family in
            try! TrajectoryCapability.normalized(
                agent: .codex,
                sessionKey: "preview-session",
                sourceKey: "preview-source",
                family: family,
                availability: family == .turnTiming ? .complete : .unavailable,
                timingQuality: family == .turnTiming ? .exact : nil,
                sourceSchemaVersion: "preview-v1",
                importerVersion: 3
            )
        }
        return TrajectorySessionReport(
            summary: TrajectorySessionSummary(
                sessionKey: "preview-session",
                agent: .codex,
                startedAtMilliseconds: turn.startedAtMilliseconds,
                endedAtMilliseconds: turn.endedAtMilliseconds,
                turnCount: 1,
                activityCount: 0,
                usageEventCount: 0,
                modelIDs: ["preview-model"]
            ),
            turns: [turn],
            activities: [],
            capabilities: capabilities,
            linkedUsageEvents: []
        )
    }()
}

struct TrajectoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            TrajectoryView(model: .preview(report: TrajectoryPreviewData.report))
        }
        .frame(width: 1_200, height: 850)
        .previewDisplayName("Trajectory metadata review")
    }
}
