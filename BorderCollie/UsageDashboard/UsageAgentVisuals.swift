import SwiftUI

extension UsageAgent {
    static let dashboardOrder: [UsageAgent] = [.codex, .claudeCode]

    /// Brand-representative, and the single source for every mark, legend chip,
    /// and callout dot.
    ///
    /// Codex uses `labelColor` — adaptive black on light, white on dark, which
    /// is OpenAI's identity and what the reference design uses. This colour is
    /// only safe because the series is carried by a full-strength line: as a
    /// large translucent area fill it reads as chrome rather than as data.
    var chartColor: Color {
        switch self {
        case .codex: Color(nsColor: .labelColor)
        case .claudeCode: .orange
        }
    }

    /// The wash beneath the line. Faint enough that two overlapping fills stay
    /// legible, since the line above it is what identifies the series.
    var chartFill: LinearGradient {
        LinearGradient(
            colors: [chartColor.opacity(0.32), chartColor.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension UsageAgent {
    var icon: AgentIcon {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

/// Brand artwork for every agent.
struct UsageAgentIconView: View {
    let agent: UsageAgent
    var size: CGFloat = 16

    /// Never apply `foregroundStyle` here: inside a `Menu` the row bridges to
    /// `NSMenuItem.image`, and a styled icon drops out entirely. Claude's art is
    /// full-colour and Codex is a template whose ambient label colour already is
    /// its `chartColor`, so no agent needs a tint.
    var body: some View {
        AgentIconView(icon: agent.icon, size: size)
    }
}
