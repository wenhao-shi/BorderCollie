import SwiftUI

extension UsageAgent {
    static let dashboardOrder: [UsageAgent] = [.codex, .claudeCode, .openCode, .pi]

    /// Hues chosen for separation between *adjacent* bands in the stacked
    /// chart, which is where confusion actually happens: the stack is drawn in
    /// `dashboardOrder`, so teal→orange→indigo→pink never puts two neighbouring
    /// hues side by side.
    ///
    /// Codex was previously `labelColor`, which made its series render in the
    /// text colour — the highest-contrast ink on screen, reading as chrome
    /// rather than as one series among four.
    var chartColor: Color {
        switch self {
        case .codex: .teal
        case .claudeCode: .orange
        case .openCode: .indigo
        case .pi: .pink
        }
    }
}

extension UsageAgent {
    /// One scale, declared once, applied to the chart. The legend and every
    /// mark read their colour from here rather than each calling `chartColor`.
    static var chartStyleScale: KeyValuePairs<String, Color> {
        [
            UsageAgent.codex.displayName: UsageAgent.codex.chartColor,
            UsageAgent.claudeCode.displayName: UsageAgent.claudeCode.chartColor,
            UsageAgent.openCode.displayName: UsageAgent.openCode.chartColor,
            UsageAgent.pi.displayName: UsageAgent.pi.chartColor,
        ]
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
