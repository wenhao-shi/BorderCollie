import SwiftUI

/// A quota bar that compares quota left with time left on one line.
///
/// Both values sit on the same "remaining" scale. The bar runs to the larger of
/// the two and splits where the smaller one ends: the usage segment keeps the
/// quota tint, the time segment is neutral. Reading it:
///
/// - neutral then tinted: quota left reaches past the time left — under pace,
///   and the tinted tail is the cushion;
/// - tinted then neutral: quota will run out before the window resets at the
///   current rate, and the neutral tail is the shortfall.
///
/// Without a known time left (unknown window or reset, or a stale tier) it is a
/// plain tinted fill. Drawn rather than a native `ProgressView`, which cannot
/// show two segments; shared by the window and the menu bar so both read alike.
struct QuotaProgressBar: View {
    let limit: UsageLimitDisplay

    @Environment(\.controlSize) private var controlSize

    var body: some View {
        // Time left moves with the clock, not with refreshes; a minute is finer
        // than one pixel of a seven-day bar and coarse enough to cost nothing.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let timeRemaining = limit.timeRemainingPercentage(now: context.date)

            SplitBar(
                usage: limit.remainingPercentage / 100,
                time: timeRemaining.map { $0 / 100 },
                tint: limit.remainingPercentage.quotaTint
            )
            .frame(height: controlSize == .small || controlSize == .mini ? 5 : 6)
            .animation(.smooth(duration: 0.28), value: limit.remainingPercentage)
            .help(timeRemaining.map(Self.helpText) ?? "")
            .accessibilityElement()
            .accessibilityValue(Self.accessibilityText(for: limit, timeRemaining: timeRemaining))
        }
    }

    static func helpText(timeRemaining: Double) -> String {
        "\(Int(timeRemaining.rounded()))% of the window's time left"
    }

    static func accessibilityText(for limit: UsageLimitDisplay, timeRemaining: Double?) -> String {
        var text = "\(limit.percentageText) remaining"
        if let timeRemaining {
            text += ", \(helpText(timeRemaining: timeRemaining))"
        }
        return text
    }
}

private struct SplitBar: View {
    /// Fractions in 0...1.
    let usage: Double
    let time: Double?
    let tint: Color

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usageEnd = width * usage

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                if let time {
                    let timeEnd = width * time
                    let split = min(usageEnd, timeEnd)
                    let end = max(usageEnd, timeEnd)
                    let usageFirst = usageEnd <= timeEnd
                    // A first segment too short to see gets no gap either, so
                    // the bar never starts with a stray sliver of space.
                    let leadingGap = split >= 1 ? gap : 0

                    segment(usageFirst ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary), from: 0, to: split)
                    segment(usageFirst ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint), from: split + leadingGap, to: end)
                } else {
                    segment(AnyShapeStyle(tint), from: 0, to: usageEnd)
                }
            }
        }
    }

    @ViewBuilder
    private func segment(_ style: AnyShapeStyle, from start: CGFloat, to end: CGFloat) -> some View {
        if end - start >= 1 {
            Capsule()
                .fill(style)
                .frame(width: end - start)
                .offset(x: start)
        }
    }
}
