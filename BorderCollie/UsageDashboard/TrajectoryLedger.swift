import SwiftUI

struct TrajectoryLedgerView: View {
    let report: TrajectorySessionReport
    let projection: TrajectoryProjectionResult
    let searchText: String
    let selectedRecordID: String?
    let rangeSelectedRecordIDs: Set<String>
    @Binding var collapsedRecordIDs: Set<String>
    let onSelect: (String?) -> Void
    let onRangeSelect: (Set<String>) -> Void
    let onSearchChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
            HStack {
                Text("Metadata ledger")
                    .font(.headline)
                Spacer()
                Text("\(rows.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Filter kind, status, model, tool, or failure category",
                text: Binding(get: { searchText }, set: onSearchChange)
            )
            .textFieldStyle(.roundedBorder)
            Table(rows, selection: tableSelection) {
                TableColumn("Kind") { row in
                    kindCell(row)
                }
                TableColumn("Model or tool") { row in
                    Text(row.label)
                        .lineLimit(1)
                }
                TableColumn("Status") { row in
                    Text(row.status)
                }
                TableColumn("Start") { row in
                    Text(row.start)
                }
                TableColumn("Duration") { row in
                    Text(row.duration)
                }
                TableColumn("Evidence") { row in
                    Text(row.evidence)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel("Trajectory metadata ledger")
        }
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: {
                if !rangeSelectedRecordIDs.isEmpty { return rangeSelectedRecordIDs }
                return selectedRecordID.map { [$0] } ?? []
            },
            set: { ids in
                if ids.count <= 1 {
                    onRangeSelect([])
                    onSelect(ids.first)
                } else {
                    onRangeSelect(ids)
                }
            }
        )
    }

    private func kindCell(_ row: TrajectoryLedgerRow) -> some View {
        let isCollapsed = collapsedRecordIDs.contains(row.id)
        let kind = row.kind
        return HStack(spacing: UsageDesign.Spacing.tight) {
            if row.hasChildren {
                Button {
                    toggle(row.id)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(kind)" : "Collapse \(kind)")
            } else {
                Color.clear.frame(width: 12)
            }
            Text(kind)
                .padding(.leading, CGFloat(row.depth) * UsageDesign.Spacing.small)
        }
    }

    private var rows: [TrajectoryLedgerRow] {
        let activities = Dictionary(uniqueKeysWithValues: report.activities.map { ($0.id, $0) })
        let turns = Dictionary(uniqueKeysWithValues: report.turns.map { ($0.id, $0) })
        let childIDs = Set(projection.records.compactMap(\.parentID))
        return projection.records.compactMap { record in
            let row = TrajectoryLedgerRow(
                record: record,
                activity: activities[record.id],
                turn: turns[record.id],
                hasChildren: childIDs.contains(record.id)
            )
            guard searchText.isEmpty || row.searchValues.contains(where: {
                $0.localizedCaseInsensitiveContains(searchText)
            }) else { return nil }
            return row
        }
    }

    private func toggle(_ id: String) {
        if collapsedRecordIDs.contains(id) {
            collapsedRecordIDs.remove(id)
        } else {
            collapsedRecordIDs.insert(id)
        }
    }
}

private struct TrajectoryLedgerRow: Identifiable {
    let record: TrajectoryProjectedRecord
    let activity: TrajectoryActivity?
    let turn: UsageActiveTurn?
    let hasChildren: Bool

    var id: String { record.id }
    var depth: Int { record.depth }
    var kind: String { activity?.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? "Turn" }
    var label: String {
        activity?.rawModelID ?? activity?.toolName ?? turn?.canonicalModelID ?? turn?.rawModelID ?? "Turn"
    }
    var status: String { activity?.status.rawValue.capitalized ?? "Completed" }
    var start: String {
        UsageDashboardFormatting.dateAndTime(
            Date(timeIntervalSince1970: TimeInterval((activity?.startedAtMilliseconds ?? turn?.startedAtMilliseconds ?? 0)) / 1_000)
        )
    }
    var duration: String {
        if let activity {
            guard let end = activity.endedAtMilliseconds else { return "Open" }
            return formatDuration(end - activity.startedAtMilliseconds)
        }
        if let turn { return formatDuration(turn.durationMilliseconds) }
        return "—"
    }
    var evidence: String {
        if let activity {
            let start = activity.startQuality.rawValue.capitalized
            let end = activity.endQuality?.rawValue.capitalized ?? "Open"
            return "\(start) start · \(end) end"
        }
        return turn?.timingQuality.rawValue.capitalized ?? "Unknown"
    }
    var searchValues: [String] {
        [
            kind,
            label,
            status,
            activity?.toolName ?? "",
            activity?.failureCategory?.rawValue ?? "",
            activity?.rawModelID ?? turn?.rawModelID ?? "",
        ]
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        let seconds = Double(milliseconds) / 1_000
        if seconds < 1 { return "\(milliseconds) ms" }
        return seconds.formatted(.number.precision(.fractionLength(0...1))) + " s"
    }
}

struct TrajectoryInspectorView: View {
    let report: TrajectorySessionReport
    let selectedRecordID: String?
    let onClose: () -> Void

    var body: some View {
        GroupBox {
            if let selectedRecordID, let detail = detail(for: selectedRecordID) {
                VStack(alignment: .leading, spacing: UsageDesign.Spacing.medium) {
                    HStack {
                        Text(detail.title)
                            .font(.headline)
                        Spacer()
                        Button("Close", systemImage: "xmark") {
                            onClose()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Close inspector")
                    }
                    detailRows(detail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No record selected",
                    systemImage: "sidebar.right",
                    description: Text("Select a timeline block or ledger row to inspect metadata.")
                )
            }
        } label: {
            Text("Inspector")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func detailRows(_ detail: TrajectoryDetail) -> some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
            detailRow("Identity", detail.id)
            detailRow("Hierarchy", detail.hierarchy)
            detailRow("Timing", detail.timing)
            detailRow("Evidence", detail.evidence)
            if let usage = detail.usage {
                detailRow("Linked usage", "\(UsageDashboardFormatting.tokens(usage.totalTokens ?? 0)) tokens")
                detailRow("Estimated cost", usage.estimatedAPICostNanodollars.map {
                    UsageDashboardFormatting.currency(nanodollars: $0)
                } ?? "Unavailable")
            }
            Text(detail.capability)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func detail(for id: String) -> TrajectoryDetail? {
        if let activity = report.activities.first(where: { $0.id == id }) {
            let usage = report.linkedUsageEvents.first { $0.id == activity.usageEventID }
            return TrajectoryDetail(
                title: activity.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                id: activity.id,
                hierarchy: activity.parentActivityID.map { "Child of \($0)" } ?? "Session root",
                timing: activity.endedAtMilliseconds.map {
                    "\(UsageDashboardFormatting.dateAndTime(Date(timeIntervalSince1970: TimeInterval(activity.startedAtMilliseconds) / 1_000))) · \(formatDuration($0 - activity.startedAtMilliseconds))"
                } ?? "Open; no terminal boundary",
                evidence: "\(activity.startQuality.rawValue.capitalized) start · \(activity.endQuality?.rawValue.capitalized ?? "No end")",
                capability: capabilityCopy(for: activity.kind),
                usage: usage
            )
        }
        guard let turn = report.turns.first(where: { $0.id == id }) else { return nil }
        return TrajectoryDetail(
            title: "Turn",
            id: turn.id,
            hierarchy: "Session root",
            timing: "\(UsageDashboardFormatting.dateAndTime(turn.startedAt)) · \(formatDuration(turn.durationMilliseconds))",
            evidence: "\(turn.timingQuality.rawValue.capitalized) boundary",
            capability: "Outer turn timing is canonical and shared with Evaluations.",
            usage: nil
        )
    }

    private func capabilityCopy(for kind: TrajectoryActivityKind) -> String {
        switch kind {
        case .modelRequest: "Model-request timing is unavailable for this source schema."
        case .tool, .subtool: "Tool lifecycle timing is unavailable for this source schema."
        case .retry: "Retry identity is available only when the source proves it."
        case .compaction: "Compaction lifecycle is unavailable for this source schema."
        }
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        let seconds = Double(milliseconds) / 1_000
        return seconds.formatted(.number.precision(.fractionLength(0...1))) + " s"
    }
}

private struct TrajectoryDetail {
    let title: String
    let id: String
    let hierarchy: String
    let timing: String
    let evidence: String
    let capability: String
    let usage: UsageEvent?
}
