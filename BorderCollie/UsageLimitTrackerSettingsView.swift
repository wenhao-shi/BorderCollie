import SwiftUI

enum UsageLimitTrackerPreferenceKey {
    static let codex = "usageLimitTracker.codex.isEnabled"
    static let cursor = "usageLimitTracker.cursor.isEnabled"
    static let claudeCode = "usageLimitTracker.claudeCode.isEnabled"
}

struct UsageLimitTrackerSettingsView: View {
    @AppStorage(UsageLimitTrackerPreferenceKey.codex) private var tracksCodex = true
    @AppStorage(UsageLimitTrackerPreferenceKey.cursor) private var tracksCursor = true
    @AppStorage(UsageLimitTrackerPreferenceKey.claudeCode) private var tracksClaudeCode = true

    var body: some View {
        Form {
            Section {
                trackerToggle("Codex", icon: .codex, isOn: $tracksCodex)
                trackerToggle("Cursor", icon: .cursor, isOn: $tracksCursor)
                trackerToggle("Claude Code", icon: .claudeCode, isOn: $tracksClaudeCode)
            } header: {
                Text("Usage limit trackers")
            } footer: {
                Text("BorderCollie hides disabled agents and stops refreshing their usage limits.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 270)
    }

    private func trackerToggle(
        _ title: String,
        icon: AgentIcon,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                AgentIconView(icon: icon, size: 20)
            }
        }
    }
}

struct UsageLimitTrackerSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        UsageLimitTrackerSettingsView()
            .previewDisplayName("Settings")
    }
}
