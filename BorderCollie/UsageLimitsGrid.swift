import SwiftUI

/// Column-aligned usage rows: label, remaining percentage, reset countdown,
/// with an optional progress bar spanning the row beneath each entry.
///
/// Shared by the main window and the menu bar panel so the two surfaces cannot
/// drift apart in wording or alignment.
struct UsageLimitsGrid: View {
    let limits: [UsageLimitDisplay]
    var showsProgressBars: Bool = true
    var font: Font = .body

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            ForEach(limits) { limit in
                GridRow {
                    Text(limit.title)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(limit.percentageText)
                        .monospacedDigit()
                        .foregroundStyle(limit.tier == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .gridColumnAlignment(.trailing)

                    Text(resetText(for: limit))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 104, alignment: .leading)
                }

                if showsProgressBars {
                    GridRow {
                        ProgressView(value: limit.remainingPercentage, total: 100)
                            .controlSize(.small)
                            .gridCellColumns(3)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .font(font)
    }

    /// Absolute reset time rather than a countdown: it stays correct between
    /// refreshes, where a countdown silently drifts.
    private func resetText(for limit: UsageLimitDisplay) -> String {
        guard let reset = limit.resetText() else {
            return "--"
        }
        return "resets \(reset)"
    }
}
