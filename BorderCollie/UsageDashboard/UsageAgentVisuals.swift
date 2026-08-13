import SwiftUI

extension UsageAgent {
    static let dashboardOrder: [UsageAgent] = [.codex, .claudeCode, .openCode, .pi]

    var chartColor: Color {
        switch self {
        case .claudeCode: .orange
        case .codex: Color(nsColor: .labelColor)
        case .openCode: .blue
        case .pi: .purple
        }
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
