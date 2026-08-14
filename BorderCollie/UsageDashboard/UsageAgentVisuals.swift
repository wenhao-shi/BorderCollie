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
        case .openCode: .indigo
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

struct UsageAgentIconView: View {
    let agent: UsageAgent
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch agent {
            case .claudeCode:
                AgentIconView(icon: .claudeCode, size: size)
            case .codex:
                AgentIconView(icon: .codex, size: size)
            case .openCode:
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(agent.chartColor)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            case .pi:
                Image(systemName: "pi")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(agent.chartColor)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
    }
}
