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

extension UsageAgent {
    var icon: AgentIcon {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .openCode: .openCode
        case .pi: .pi
        }
    }

    /// Whether the asset needs a colour applied.
    ///
    /// Claude's artwork is authored full-colour. Codex is a template whose
    /// ambient label colour already *is* its `chartColor`. Only OpenCode and Pi
    /// are templates wanting a colour that differs from the ambient one.
    var iconNeedsTint: Bool {
        switch self {
        case .claudeCode, .codex: false
        case .openCode, .pi: true
        }
    }
}

/// Brand artwork for every agent.
struct UsageAgentIconView: View {
    let agent: UsageAgent
    var size: CGFloat = 16
    /// Set `false` inside a `Menu`.
    ///
    /// Menu rows bridge to `NSMenuItem.image`, and an icon carrying a
    /// `foregroundStyle` does not survive that extraction — the row renders with
    /// no image at all rather than an untinted one. Monochrome template images
    /// taking the menu's own tint is also the native idiom for menu items.
    var isTinted = true

    var body: some View {
        if isTinted, agent.iconNeedsTint {
            AgentIconView(icon: agent.icon, size: size)
                .foregroundStyle(agent.chartColor)
        } else {
            AgentIconView(icon: agent.icon, size: size)
        }
    }
}
