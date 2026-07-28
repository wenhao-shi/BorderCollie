//
//  ContentView.swift
//  BorderCollie
//
//  Created by Mason on 7/2/26.
//

import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection? = .codex

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Codex", systemImage: "terminal")
                    .tag(SidebarSection.codex)
                Label("Cursor", systemImage: "cursorarrow.rays")
                    .tag(SidebarSection.cursor)
                Label("Claude Code", systemImage: "sparkles")
                    .tag(SidebarSection.claudeCode)
            }
            .listStyle(.sidebar)
            .navigationTitle("BorderCollie")
        } detail: {
            switch selection ?? .codex {
            case .codex:
                CodexUsageView()
            case .cursor:
                CursorUsageView()
            case .claudeCode:
                ClaudeUsageView()
            }
        }
    }
}

private enum SidebarSection: String, Identifiable {
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
