import SwiftUI

struct TrajectoryTimelineView: View {
    let report: TrajectorySessionReport
    let projection: TrajectoryProjectionResult
    let mode: TrajectoryTimeMode
    let selectedRecordID: String?
    let rangeSelectedRecordIDs: Set<String>
    let onSelect: (String?) -> Void
    let onRangeSelect: (Set<String>) -> Void

    @State private var rangeAnchor: CGFloat?
    @State private var rangeSelection: ClosedRange<Double>?

    init(
        report: TrajectorySessionReport,
        projection: TrajectoryProjectionResult,
        mode: TrajectoryTimeMode,
        selectedRecordID: String?,
        rangeSelectedRecordIDs: Set<String>,
        onSelect: @escaping (String?) -> Void,
        onRangeSelect: @escaping (Set<String>) -> Void
    ) {
        self.report = report
        self.projection = projection
        self.mode = mode
        self.selectedRecordID = selectedRecordID
        self.rangeSelectedRecordIDs = rangeSelectedRecordIDs
        self.onSelect = onSelect
        self.onRangeSelect = onRangeSelect
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
                HStack {
                    Text("Overview")
                        .font(.headline)
                    Spacer()
                    Text(mode.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(TrajectoryLane.allCases, id: \.rawValue) { lane in
                    laneRow(lane)
                }
                Text(axisCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(UsageDesign.Spacing.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trajectory overview in \(mode.label)")
        .onChange(of: mode) {
            rangeSelection = nil
            rangeAnchor = nil
            onRangeSelect([])
        }
    }

    private func laneRow(_ lane: TrajectoryLane) -> some View {
        HStack(spacing: UsageDesign.Spacing.small) {
            Text(lane.label)
                .font(.caption)
                .frame(width: 54, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 1)
                    if let rangeSelection {
                        rangeOverlay(rangeSelection, width: geometry.size.width)
                    }
                    ForEach(visibleRecords.filter { $0.lane == lane }) { record in
                        recordBlock(record, width: geometry.size.width)
                    }
                }
                .simultaneousGesture(rangeGesture(width: geometry.size.width))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
    }

    private func recordBlock(_ record: TrajectoryProjectedRecord, width: CGFloat) -> some View {
        let span = max(projection.axisUpperBound - projection.axisLowerBound, 1)
        let start = CGFloat((record.axisStart - projection.axisLowerBound) / span) * width
        let endValue = record.axisEnd ?? record.axisStart
        let end = CGFloat((endValue - projection.axisLowerBound) / span) * width
        let recordWidth = record.axisEnd == nil || record.isPoint ? 7 : max(end - start, 7)
        let color = record.lane.color
        return Button {
            rangeSelection = nil
            onRangeSelect([])
            onSelect(record.id)
        } label: {
            ZStack {
                if record.axisEnd == nil {
                    Rectangle()
                        .fill(color)
                        .frame(width: 2, height: 22)
                } else if record.isPoint {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                } else {
                    RoundedRectangle(cornerRadius: UsageDesign.Radius.inline, style: .continuous)
                        .fill(color.opacity(record.isUnscoped ? 0.35 : 0.8))
                }
            }
            .frame(width: recordWidth, height: 24)
            .overlay {
                if selectedRecordID == record.id || rangeSelectedRecordIDs.contains(record.id) {
                    RoundedRectangle(cornerRadius: UsageDesign.Radius.inline, style: .continuous)
                        .stroke(.primary, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .offset(x: start)
        .help(recordTiming(record))
        .accessibilityLabel(recordLabel(record))
        .accessibilityValue(recordTiming(record))
    }

    private var axisCaption: String {
        switch mode {
        case .order:
            return "Equal source-order slots; width is not duration"
        case .activeTime:
            return "Recorded time with gaps outside active turns removed"
        case .clockTime:
            return "Wall-clock time; idle gaps preserved"
        }
    }

    private func rangeOverlay(_ range: ClosedRange<Double>, width: CGFloat) -> some View {
        let lower = pixel(for: range.lowerBound, width: width)
        let upper = pixel(for: range.upperBound, width: width)
        return Rectangle()
            .fill(Color.accentColor.opacity(0.14))
            .frame(width: max(1, upper - lower), height: 24)
            .offset(x: lower)
            .allowsHitTesting(false)
    }

    private func rangeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if rangeAnchor == nil { rangeAnchor = value.startLocation.x }
                guard let rangeAnchor else { return }
                rangeSelection = valueRange(start: rangeAnchor, end: value.location.x, width: width)
            }
            .onEnded { value in
                guard let rangeAnchor else { return }
                let range = valueRange(start: rangeAnchor, end: value.location.x, width: width)
                self.rangeAnchor = nil
                rangeSelection = range
                let ids = TrajectoryProjection.recordIDs(overlapping: range, in: projection)
                onRangeSelect(ids)
            }
    }

    private func valueRange(start: CGFloat, end: CGFloat, width: CGFloat) -> ClosedRange<Double> {
        let plotWidth = max(width, 1)
        let lowerPixel = min(max(start, 0), plotWidth)
        let upperPixel = min(max(end, 0), plotWidth)
        let span = max(projection.axisUpperBound - projection.axisLowerBound, 1)
        let lowerValue = projection.axisLowerBound + Double(min(lowerPixel, upperPixel) / plotWidth) * span
        let upperValue = projection.axisLowerBound + Double(max(lowerPixel, upperPixel) / plotWidth) * span
        return lowerValue...upperValue
    }

    private func pixel(for value: Double, width: CGFloat) -> CGFloat {
        let span = max(projection.axisUpperBound - projection.axisLowerBound, 1)
        return CGFloat((value - projection.axisLowerBound) / span) * width
    }

    private var visibleRecords: [TrajectoryProjectedRecord] {
        guard mode == .activeTime else { return projection.records }
        let outside = Set(projection.issues.compactMap { issue in
            issue.kind == .outsideActiveTime ? issue.recordID : nil
        })
        return projection.records.filter { !outside.contains($0.id) }
    }

    private func recordLabel(_ record: TrajectoryProjectedRecord) -> String {
        let kind = report.activities.first(where: { $0.id == record.id })?.kind.rawValue
            ?? (record.lane == .turn ? "turn" : record.lane.rawValue)
        return "\(kind) record"
    }

    private func recordTiming(_ record: TrajectoryProjectedRecord) -> String {
        guard let end = record.axisEnd else { return "Open; start marker only" }
        let width = (end - record.axisStart).formatted(.number.precision(.fractionLength(1)))
        return record.isPoint ? "Point event" : "Projected span \(width)"
    }
}

private extension TrajectoryLane {
    var label: String {
        switch self {
        case .turn: "Turn"
        case .model: "Model"
        case .tools: "Tools"
        }
    }

    var color: Color {
        switch self {
        case .turn: .secondary
        case .model: .accentColor
        case .tools: .orange
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
