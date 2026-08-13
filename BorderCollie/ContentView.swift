//
//  ContentView.swift
//  BorderCollie
//
//  Created by Mason on 7/2/26.
//

import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .usage

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Usage", systemImage: "chart.xyaxis.line")
                    .tag(SidebarSection.usage)
                sidebarLabel("Codex", icon: .codex)
                    .tag(SidebarSection.codex)
                sidebarLabel("Cursor", icon: .cursor)
                    .tag(SidebarSection.cursor)
                sidebarLabel("Claude Code", icon: .claudeCode)
                    .tag(SidebarSection.claudeCode)
            }
            .listStyle(.sidebar)
            .navigationTitle("BorderCollie")
        } detail: {
            switch selection ?? .usage {
            case .usage:
                UsageDashboardView()
            case .codex:
                CodexUsageView()
            case .cursor:
                CursorUsageView()
            case .claudeCode:
                ClaudeUsageView()
            }
        }
    }

    private func sidebarLabel(_ title: String, icon: AgentIcon) -> some View {
        HStack(spacing: 8) {
            AgentIconView(icon: icon, size: 16)
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private enum SidebarSection: String, Identifiable {
    case usage
    case codex
    case cursor
    case claudeCode

    var id: String { rawValue }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("BorderCollie")
    }
}
