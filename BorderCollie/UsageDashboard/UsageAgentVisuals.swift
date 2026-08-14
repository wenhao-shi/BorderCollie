import SwiftUI

extension UsageAgent {
    static let dashboardOrder: [UsageAgent] = [.codex, .claudeCode, .openCode, .pi]

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
        case .openCode: .blue
        case .pi: .pink
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

/// Brand artwork for every agent.
///
/// OpenCode and Pi ship as template silhouettes (`fill="currentColor"`), so they
/// take `chartColor` and match their series. Codex is also a template and picks
/// up the ambient label colour, which is its `chartColor`. Claude's asset is
/// full-colour and renders as authored.
struct UsageAgentIconView: View {
    let agent: UsageAgent
    var size: CGFloat = 16

    var body: some View {
        switch agent {
        case .claudeCode:
            AgentIconView(icon: .claudeCode, size: size)
        case .codex:
            AgentIconView(icon: .codex, size: size)
        case .openCode:
            AgentIconView(icon: .openCode, size: size)
                .foregroundStyle(agent.chartColor)
        case .pi:
            AgentIconView(icon: .pi, size: size)
                .foregroundStyle(agent.chartColor)
        }
    }
}
