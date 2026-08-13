import SwiftUI

struct EvaluationRunsView: View {
    @StateObject private var model = EvaluationRunsModel.live()
    @SceneStorage("evaluationRuns.selection") private var selectedRunID = ""
    @State private var creationMode: EvaluationCreationMode?
    @State private var pendingDeletion: EvaluationRun?

    var body: some View {
        HSplitView {
            runList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            detail
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 640)
        .navigationTitle("Evaluations")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Start Evaluation…", systemImage: "record.circle") {
                        creationMode = .live
                    }
                    .disabled(!model.canStart)

                    Button("Add Past Evaluation…", systemImage: "calendar.badge.plus") {
                        creationMode = .past
                    }
                } label: {
                    Label("New evaluation", systemImage: "plus")
                }
                .disabled(model.isRefreshing)

                Button {
                    Task {
                        await model.refreshUsage(selectedRunID: selectedRun?.id)
                        await selectInitialRunIfNeeded()
                    }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh evaluations", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await model.loadInitially()
            await selectInitialRunIfNeeded()
        }
        .onChange(of: selectedRunID) {
            Task { await model.loadReport(runID: selectedRun?.id) }
        }
        .sheet(item: $creationMode) { mode in
            EvaluationCreationSheet(mode: mode) { name, interval in
                let id: String?
                switch mode {
                case .live:
                    id = await model.start(name: name)
                case .past:
                    guard let interval else { return }
                    id = await model.createPast(name: name, interval: interval)
                }
                if let id { selectedRunID = id }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "Evaluation")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let run = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    await model.delete(runID: run.id)
                    selectedRunID = model.runs.first?.id ?? ""
                    await model.loadReport(runID: selectedRun?.id)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("The saved evaluation scope will be removed. Imported usage history is not deleted.")
        }
    }

    private var runList: some View {
        List(selection: $selectedRunID) {
            if model.runs.isEmpty {
                ContentUnavailableView(
                    "No evaluations",
                    systemImage: "stopwatch",
                    description: Text("Start a run now or add one from a past time period.")
                )
            } else {
                ForEach(model.runs) { run in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(run.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if run.isActive {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel("Running")
                            }
                        }
                        Text(runListDetail(run))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(run.id)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDeletion = run
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let errorMessage = model.errorMessage, selectedRun == nil {
            ContentUnavailableView(
                "Evaluations unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if model.isLoading {
            ProgressView("Loading evaluation…")
        } else if let report = model.report, report.run.id == selectedRun?.id {
            EvaluationRunDetailView(
                report: report,
                isRefreshing: model.isRefreshing,
                errorMessage: model.errorMessage,
                onStop: {
                    Task { await model.stop(runID: report.run.id) }
                },
                onSessionChange: { sessionKey, isSelected in
                    Task {
                        await model.setSession(
                            runID: report.run.id,
                            sessionKey: sessionKey,
                            isSelected: isSelected
                        )
                    }
                }
            )
        } else if selectedRun != nil {
            ProgressView("Loading evaluation…")
        } else {
            ContentUnavailableView(
                "Select an evaluation",
                systemImage: "stopwatch",
                description: Text("Saved task usage, cost, and active-time accounting appears here.")
            )
        }
    }

    private var selectedRun: EvaluationRun? {
        model.runs.first { $0.id == selectedRunID }
    }

    private func selectInitialRunIfNeeded() async {
        if selectedRun == nil {
            selectedRunID = model.runs.first?.id ?? ""
        }
        await model.loadReport(runID: selectedRun?.id)
    }

    private func runListDetail(_ run: EvaluationRun) -> String {
        if run.isActive {
            return "Running since \(UsageDashboardFormatting.dateAndTime(run.startedAt))"
        }
        guard let interval = run.interval() else { return UsageDashboardFormatting.dateAndTime(run.startedAt) }
        return UsageDashboardFormatting.rollingInterval(interval)
    }
}

private struct EvaluationRunDetailView: View {
    let report: UsageEvaluationReport
    let isRefreshing: Bool
    let errorMessage: String?
    let onStop: () -> Void
    let onSessionChange: (String, Bool) -> Void

    @State private var showsTurns = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if report.run.isActive {
                    activeState
                } else {
                    sessionSelection
                    summaryCards
                    tokenBreakdown
                    modelBreakdown
                    turnBreakdown
                    coverage
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.run.name)
                    .font(.largeTitle.weight(.semibold))
                if report.run.isActive {
                    Text("Started \(UsageDashboardFormatting.dateAndTime(report.run.startedAt))")
                        .foregroundStyle(.secondary)
                } else if let interval = report.run.interval() {
                    Text(UsageDashboardFormatting.rollingInterval(interval))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if report.run.isActive {
                Button("Stop Evaluation", systemImage: "stop.circle.fill", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isRefreshing)
            }
        }
    }

    private var activeState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Evaluation running", systemImage: "record.circle")
                .font(.headline)
                .foregroundStyle(.red)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Elapsed wall time: \(EvaluationFormatting.duration(milliseconds: max(UsageEpoch.milliseconds(context.date) - report.run.startedAtMilliseconds, 0)))")
                    .font(.title3.monospacedDigit())
            }
            Text("Run the task in one or more agent sessions, then stop the evaluation. BorderCollie will refresh local histories and select every session active in this interval for review.")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sessionSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Included sessions")
                    .font(.headline)
                Spacer()
                Text("\(report.selectedSessionKeys.count) of \(report.availableSessions.count)")
                    .foregroundStyle(.secondary)
            }

            if report.availableSessions.isEmpty {
                ContentUnavailableView(
                    "No sessions found",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("No supported agent history overlaps this interval. Refresh after the sessions have been written to disk.")
                )
                .frame(minHeight: 120)
            } else {
                ForEach(Array(report.availableSessions.enumerated()), id: \.element.id) { index, session in
                    Toggle(
                        isOn: Binding(
                            get: { report.selectedSessionKeys.contains(session.sessionKey) },
                            set: { onSessionChange(session.sessionKey, $0) }
                        )
                    ) {
                        HStack(spacing: 10) {
                            UsageAgentIconView(agent: session.agent, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(session.agent.displayName) · Session \(index + 1)")
                                Text(sessionDetail(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            summaryCard(
                "Effective wall",
                EvaluationFormatting.duration(milliseconds: report.timing.effectiveWallTimeMilliseconds),
                "Parallel overlap counted once"
            )
            summaryCard(
                "Agent time",
                EvaluationFormatting.duration(milliseconds: report.timing.additiveAgentTimeMilliseconds),
                "Selected sessions added"
            )
            summaryCard(
                "Human idle",
                EvaluationFormatting.duration(milliseconds: report.timing.humanIdleTimeMilliseconds),
                "Outside active turn intervals"
            )
            summaryCard(
                "Tokens",
                UsageDashboardFormatting.tokens(report.totalTokens),
                "\(report.coverage.completeEvents) complete events"
            )
            summaryCard(
                "API-equivalent cost",
                UsageDashboardFormatting.currency(nanodollars: report.estimatedCostNanodollars),
                "\(report.coverage.pricedEvents) priced events"
            )
        }
    }

    private var tokenBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token breakdown")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                tokenMetric("In", report.inputTokens)
                tokenMetric("Cache write", report.cacheWriteTokens)
                tokenMetric("Cache read", report.cacheReadTokens)
                tokenMetric("Out", report.outputTokens, detail: report.reasoningOutputTokens > 0
                    ? "\(UsageDashboardFormatting.tokens(report.reasoningOutputTokens)) reasoning"
                    : nil)
                metric("Input cache hit", UsageDashboardFormatting.percent(report.inputCacheHitRate))
                metric("Output share", UsageDashboardFormatting.percent(report.outputShare))
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By model")
                .font(.headline)
            if report.models.isEmpty {
                Text("No complete token events or active turns are selected.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow {
                            tableHeader("Model")
                            tableHeader("Active time")
                            tableHeader("In")
                            tableHeader("Cache write")
                            tableHeader("Cache read")
                            tableHeader("Out")
                            tableHeader("Total")
                            tableHeader("Cost")
                        }
                        Divider().gridCellColumns(8)
                        ForEach(report.models) { row in
                            GridRow {
                                HStack(spacing: 7) {
                                    UsageAgentIconView(agent: row.agent, size: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.modelID).lineLimit(1)
                                        Text(row.agent.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                value(EvaluationFormatting.duration(milliseconds: row.activeTimeMilliseconds))
                                value(UsageDashboardFormatting.tokens(row.inputTokens))
                                value(UsageDashboardFormatting.tokens(row.cacheWriteTokens))
                                value(UsageDashboardFormatting.tokens(row.cacheReadTokens))
                                value(UsageDashboardFormatting.tokens(row.outputTokens))
                                value(UsageDashboardFormatting.tokens(row.totalTokens))
                                value(modelCost(row))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var turnBreakdown: some View {
        DisclosureGroup(isExpanded: $showsTurns) {
            if report.turns.isEmpty {
                Text("No complete active turns are available for the selected sessions.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(report.turns.enumerated()), id: \.element.id) { index, turn in
                        HStack(spacing: 10) {
                            UsageAgentIconView(agent: turn.agent, size: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Turn \(index + 1) · \(turn.modelID)")
                                Text("\(EvaluationFormatting.dateTime(milliseconds: turn.startedAtMilliseconds)) · \(turn.timingQuality == .exact ? "exact markers" : "inferred boundaries")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(EvaluationFormatting.duration(milliseconds: turn.durationMilliseconds))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        if index < report.turns.count - 1 { Divider() }
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            HStack {
                Text("By turn")
                    .font(.headline)
                Spacer()
                Text("\(report.turns.count)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coverage")
                .font(.headline)
            Text("\(report.timing.exactTurns) turns use explicit timing markers; \(report.timing.inferredTurns) use message-boundary inference.")
            if report.coverage.partialEvents > 0 {
                Text("\(report.coverage.partialEvents) partial events are excluded from token and cost totals.")
            }
            if report.coverage.unpricedCompleteEvents > 0 {
                Text("\(report.coverage.unpricedCompleteEvents) complete events have no verified price; tokens include them and cost does not.")
            }
            Text("Agent-active time includes model generation, tools, subprocesses, and network waits. Idle gaps after an agent completes and before the next human submission are excluded.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func sessionDetail(_ session: EvaluationSessionSummary) -> String {
        let models = session.modelIDs.isEmpty ? "Unknown model" : session.modelIDs.joined(separator: ", ")
        return "\(UsageDashboardFormatting.dateAndTime(session.startedAt)) · \(session.activeTurnCount) turns · \(session.eventCount) events · \(models)"
    }

    private func summaryCard(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func tokenMetric(_ title: String, _ value: Int64, detail: String? = nil) -> some View {
        metric(title, UsageDashboardFormatting.tokens(value), detail: detail)
    }

    private func metric(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func modelCost(_ row: EvaluationModelBreakdown) -> String {
        guard row.pricedEvents > 0 else { return row.completeEvents > 0 ? "Unpriced" : "—" }
        return UsageDashboardFormatting.currency(nanodollars: row.estimatedCostNanodollars)
            + (row.pricedEvents < row.completeEvents ? "*" : "")
    }
}

private enum EvaluationCreationMode: String, Identifiable {
    case live
    case past

    var id: String { rawValue }
}

private struct EvaluationCreationSheet: View {
    let mode: EvaluationCreationMode
    let onSave: (String, DateInterval?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var startedAt = Date().addingTimeInterval(-3_600)
    @State private var endedAt = Date()
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode == .live ? "Start Evaluation" : "Add Past Evaluation")
                .font(.title2.weight(.semibold))

            TextField("Task name", text: $name, prompt: Text("e.g. Implement paged attention"))

            if mode == .past {
                DatePicker(
                    "Start",
                    selection: $startedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                DatePicker(
                    "End",
                    selection: $endedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                if endedAt <= startedAt {
                    Text("End must be later than start.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("BorderCollie records the start immediately. Stop the evaluation after the selected agent sessions finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(mode == .live ? "Start" : "Create") {
                    isSaving = true
                    Task {
                        let interval = mode == .past ? DateInterval(start: startedAt, end: endedAt) : nil
                        await onSave(name, interval)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (mode == .past && endedAt <= startedAt)
                )
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private enum EvaluationFormatting {
    static func duration(milliseconds: Int64) -> String {
        let totalSeconds = max(milliseconds, 0) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func dateTime(milliseconds: Int64) -> String {
        UsageDashboardFormatting.dateAndTime(
            Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        )
    }
}
