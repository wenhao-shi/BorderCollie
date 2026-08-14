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
                // Two kinds of destination live here: screens over the imported
                // history, and screens over live provider quota. They refresh on
                // different clocks and hold different data, so they are labelled
                // rather than run together in one flat list.
                Section("History") {
                    Label("Usage", systemImage: "chart.xyaxis.line")
                        .tag(SidebarSection.usage)
                    Label("Evaluations", systemImage: "stopwatch")
                        .tag(SidebarSection.evaluations)
                }

                Section("Live quota") {
                    sidebarLabel("Codex", icon: .codex)
                        .tag(SidebarSection.codex)
                    sidebarLabel("Cursor", icon: .cursor)
                        .tag(SidebarSection.cursor)
                    sidebarLabel("Claude Code", icon: .claudeCode)
                        .tag(SidebarSection.claudeCode)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch selection ?? .usage {
            case .usage:
                UsageDashboardView()
            case .evaluations:
                EvaluationRunsView()
            case .codex:
                CodexUsageView()
            case .cursor:
                CursorUsageView()
            case .claudeCode:
                ClaudeUsageView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }

    /// `Label`'s icon slot rather than a hand-rolled `HStack`, so bundled agent
    /// artwork lands in the same icon column as the SF Symbols above it.
    private func sidebarLabel(_ title: String, icon: AgentIcon) -> some View {
        Label {
            Text(title)
        } icon: {
            AgentIconView(icon: icon, size: 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private enum SidebarSection: String, Identifiable {
    case usage
    case evaluations
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
