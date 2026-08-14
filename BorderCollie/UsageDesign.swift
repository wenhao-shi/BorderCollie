import SwiftUI

/// The app's shared visual scale.
///
/// Before this existed the two dashboards had drifted to five corner radii and
/// nine paddings, and the same metric tile was written three times with three
/// different sets of both. Everything that draws a container or a number now
/// derives from here, so a change lands once.
enum UsageDesign {
    /// Three radii, one per nesting depth. `inline` is for things that sit
    /// inside a card (chips, tooltips), `card` for a card, `container` for a
    /// panel that holds cards.
    enum Radius {
        static let inline: CGFloat = 6
        static let card: CGFloat = 10
        static let container: CGFloat = 14
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 24
    }

    /// `.continuous` throughout: `RoundedRectangle(cornerRadius:)` defaults to
    /// `.circular`, which is not the curve AppKit draws.
    static let inlineShape = RoundedRectangle(cornerRadius: Radius.inline, style: .continuous)
    static let cardShape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    static let containerShape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
}

extension Font {
    static let metricLabel = Font.caption
    static let metricValue = Font.title3.monospacedDigit()
    static let metricDetail = Font.caption

    /// System font, regular weight. macOS renders display-size numbers in SF
    /// Pro; SF Rounded reads as watchOS.
    static let heroValue = Font.system(size: 34, weight: .regular).monospacedDigit()
}

/// Label, value, optional qualifier. The only metric presentation in the app.
///
/// Draws no background of its own — containers supply one, so a tile reads the
/// same whether it sits in a `GroupBox` or a bare grid.
struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
            Text(title)
                .font(.metricLabel)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.metricValue)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.28), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let detail {
                Text(detail)
                    .font(.metricDetail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }
}

/// Threshold tint for a consumed-quota bar.
///
/// Colour reinforces the percentage that is already written beside the bar; it
/// is never the only channel carrying the value.
extension Double {
    var quotaTint: Color {
        switch self {
        case ..<75: .accentColor
        case ..<90: .orange
        default: .red
        }
    }
}
