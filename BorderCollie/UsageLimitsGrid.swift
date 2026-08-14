import SwiftUI

/// Column-aligned usage rows: label, used percentage, reset time, with an
/// optional progress bar spanning the row beneath each entry.
///
/// The compact layout, used by the menu-bar panel. The window uses a grouped
/// `Form` instead, because a 360-point popover and a 940-point pane do not want
/// the same layout. Wording stays shared via `UsageLimitDisplay`, which is where
/// the two surfaces would otherwise drift apart.
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

                    Text(UsageLimitDisplay.resetLabel(for: limit))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 104, alignment: .leading)
                }

                if showsProgressBars {
                    GridRow {
                        ProgressView(value: limit.usedPercentage, total: 100)
                            .controlSize(.small)
                            .tint(limit.usedPercentage.quotaTint)
                            .gridCellColumns(3)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .font(font)
    }
}
