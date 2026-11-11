import SwiftUI

/// Brand icon for a tracked agent.
///
/// Codex ships as a template image and takes the surrounding foreground
/// style, so it stays legible in both appearances. Claude's icon carries its
/// own brand fill and renders as authored.
enum AgentIcon: String, Sendable {
    case codex
    case claudeCode

    var resource: ImageResource {
        switch self {
        case .codex:
            .agentIconCodex
        case .claudeCode:
            .agentIconClaude
        }
    }
}

struct AgentIconView: View {
    let icon: AgentIcon
    var size: CGFloat

    init(icon: AgentIcon, size: CGFloat = 28) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(icon.resource)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension NSImage {
    /// Status-bar icon, sized to the menu bar and marked as a template so macOS
    /// inverts it with the menu bar appearance.
    static let borderCollieMenuBarIcon: NSImage = {
        guard let image = NSImage(resource: .menuBarIcon).copy() as? NSImage else {
            return NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
