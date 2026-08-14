import SwiftUI

struct EvaluationRunsView: View {
    @StateObject private var model = EvaluationRunsModel.live()
    @SceneStorage("evaluationRuns.selection") private var selectedRunID = ""
    @State private var creationMode: EvaluationCreationMode?
    @State private var pendingDeletion: EvaluationRun?

    var body: some View {
        HSplitView {
            runList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selectedRun?.name ?? "Evaluations")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let report = model.report, report.run.isActive, report.run.id == selectedRun?.id {
                    // A destructive primary action belongs in the toolbar with
                    // the other verbs, not floating in the scrolled content.
                    Button("Stop Evaluation", systemImage: "stop.circle.fill") {
                        Task { await model.stop(runID: report.run.id) }
                    }
                    .tint(.red)
                    .disabled(model.isRefreshing)
                }

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

    private var navigationSubtitle: String {
        guard let run = selectedRun else { return "" }
        if run.isActive {
            return "Running since \(UsageDashboardFormatting.dateAndTime(run.startedAt))"
        }
        guard let interval = run.interval() else { return "" }
        return UsageDashboardFormatting.rollingInterval(interval)
    }

    /// `.inset`, not `.sidebar`. This list sits inside the detail column, so
    /// sidebar styling put a second thing that looks like a source list next to
    /// the real one, with the selection tint of a sidebar it is not.
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
                        HStack(spacing: UsageDesign.Spacing.small) {
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
                    .padding(.vertical, 2)
                    .tag(run.id)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDeletion = run
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
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
                errorMessage: model.errorMessage,
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
    let errorMessage: String?
    let onSessionChange: (String, Bool) -> Void

    @State private var showsTurns = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.section) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .padding(UsageDesign.Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: UsageDesign.cardShape)
                        .overlay(UsageDesign.cardShape.stroke(.separator))
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
            .padding(UsageDesign.Spacing.section)
        }
    }

    private var activeState: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(EvaluationFormatting.duration(milliseconds: max(UsageEpoch.milliseconds(context.date) - report.run.startedAtMilliseconds, 0)))
                        .font(.heroValue)
                        .accessibilityLabel("Elapsed wall time")
                }
                Text("Elapsed wall time")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Run the task in one or more agent sessions, then stop the evaluation. BorderCollie will refresh local histories and select every session active in this interval for review.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UsageDesign.Spacing.small)
        } label: {
            Label("Evaluation running", systemImage: "record.circle")
                .font(.headline)
                .foregroundStyle(.red)
        }
    }

    private var sessionSelection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
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
                            HStack(spacing: UsageDesign.Spacing.small) {
                                UsageAgentIconView(agent: session.agent, size: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    // Start time leads: a positional index is not
                                    // an identity, and it changes meaning as soon
                                    // as the list re-sorts.
                                    Text("\(UsageDashboardFormatting.dateAndTime(session.startedAt)) · \(session.agent.displayName)")
                                    Text(sessionDetail(session, index: index))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UsageDesign.Spacing.small)
        } label: {
            HStack {
                Text("Included sessions")
                    .font(.headline)
                Spacer()
                Text("\(report.selectedSessionKeys.count) of \(report.availableSessions.count)")
                    .foregroundStyle(.secondary)
                if !report.availableSessions.isEmpty {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        for session in report.availableSessions {
                            onSessionChange(session.sessionKey, !allSelected)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var allSelected: Bool {
        !report.availableSessions.isEmpty
            && report.availableSessions.allSatisfy { report.selectedSessionKeys.contains($0.sessionKey) }
    }

    private var summaryCards: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: UsageDesign.Spacing.large, alignment: .top)],
                spacing: UsageDesign.Spacing.large
            ) {
                MetricTile(
                    title: "Effective wall",
                    value: EvaluationFormatting.duration(milliseconds: report.timing.effectiveWallTimeMilliseconds),
                    detail: "Parallel overlap counted once"
                )
                MetricTile(
                    title: "Agent time",
                    value: EvaluationFormatting.duration(milliseconds: report.timing.additiveAgentTimeMilliseconds),
                    detail: "Selected sessions added"
                )
                MetricTile(
                    title: "Human idle",
                    value: EvaluationFormatting.duration(milliseconds: report.timing.humanIdleTimeMilliseconds),
                    detail: "Outside active turn intervals"
                )
                MetricTile(
                    title: "Tokens",
                    value: UsageDashboardFormatting.tokens(report.totalTokens),
                    detail: "\(report.coverage.completeEvents) complete events"
                )
                MetricTile(
                    title: "API-equivalent cost",
                    value: UsageDashboardFormatting.currency(nanodollars: report.estimatedCostNanodollars),
                    detail: "\(report.coverage.pricedEvents) priced events"
                )
            }
            .padding(UsageDesign.Spacing.small)
        } label: {
            Text("Summary")
                .font(.headline)
        }
    }

    private var tokenBreakdown: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: UsageDesign.Spacing.medium, alignment: .top)],
                spacing: UsageDesign.Spacing.medium
            ) {
                MetricTile(title: "In", value: UsageDashboardFormatting.tokens(report.inputTokens))
                MetricTile(title: "Cache write", value: UsageDashboardFormatting.tokens(report.cacheWriteTokens))
                MetricTile(title: "Cache read", value: UsageDashboardFormatting.tokens(report.cacheReadTokens))
                MetricTile(
                    title: "Out",
                    value: UsageDashboardFormatting.tokens(report.outputTokens),
                    detail: report.reasoningOutputTokens > 0
                        ? "\(UsageDashboardFormatting.tokens(report.reasoningOutputTokens)) reasoning"
                        : nil
                )
                MetricTile(title: "Input cache hit", value: UsageDashboardFormatting.percent(report.inputCacheHitRate))
                MetricTile(title: "Output share", value: UsageDashboardFormatting.percent(report.outputShare))
            }
            .padding(UsageDesign.Spacing.small)
        } label: {
            Text("Token breakdown")
                .font(.headline)
        }
    }

    /// A `Grid`, not a `Table`. A `Table` brings its own scroll view, and this
    /// pane is already inside one — the nested-scroll trap is worse here than
    /// the sorting a `Table` would add, for a handful of rows.
    private var modelBreakdown: some View {
        GroupBox {
            if report.models.isEmpty {
                Text("No complete token events or active turns are selected.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: UsageDesign.Spacing.large, verticalSpacing: 9) {
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
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("By model")
                .font(.headline)
        }
    }

    private var turnBreakdown: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showsTurns) {
                if report.turns.isEmpty {
                    Text("No complete active turns are available for the selected sessions.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, UsageDesign.Spacing.small)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(report.turns.enumerated()), id: \.element.id) { index, turn in
                            HStack(spacing: UsageDesign.Spacing.medium) {
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
                            .padding(.vertical, UsageDesign.Spacing.small)
                            if index < report.turns.count - 1 { Divider() }
                        }
                    }
                    .padding(.top, UsageDesign.Spacing.tight)
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
        }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
            Text("Coverage")
                .font(.headline)
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
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
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionDetail(_ session: EvaluationSessionSummary, index: Int) -> String {
        let models = session.modelIDs.isEmpty ? "Unknown model" : session.modelIDs.joined(separator: ", ")
        return "Session \(index + 1) · \(session.activeTurnCount) turns · \(session.eventCount) events · \(models)"
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
        VStack(alignment: .leading, spacing: 0) {
            // A `Form`, so the field labels share one alignment column. The
            // hand-built stack labelled the date pickers but left the name field
            // with only a placeholder, so nothing lined up.
            Form {
                TextField("Task name", text: $name, prompt: Text("e.g. Implement paged attention"))

                if mode == .past {
                    DatePicker("Start", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $endedAt, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    if mode == .past, endedAt <= startedAt {
                        Label("End must be later than start.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if mode == .live {
                        Text("BorderCollie records the start immediately. Stop the evaluation after the selected agent sessions finish.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode == .live ? "Start" : "Create") {
                    isSaving = true
                    Task {
                        let interval = mode == .past ? DateInterval(start: startedAt, end: endedAt) : nil
                        await onSave(name, interval)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(UsageDesign.Spacing.large)
        }
        .frame(width: 460)
    }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode == .live || endedAt > startedAt)
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
