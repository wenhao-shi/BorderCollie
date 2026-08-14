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
            // Flat: with the three provider pages merged into one Live quota
            // destination there are three items total, and section headers over
            // a single row are noise.
            List(selection: $selection) {
                Label("Usage", systemImage: "chart.xyaxis.line")
                    .tag(SidebarSection.usage)
                Label("Evaluations", systemImage: "stopwatch")
                    .tag(SidebarSection.evaluations)
                Label("Live quota", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .tag(SidebarSection.liveQuota)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch selection ?? .usage {
            case .usage:
                UsageDashboardView()
            case .evaluations:
                EvaluationRunsView()
            case .liveQuota:
                LiveQuotaView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }
}

private enum SidebarSection: String, Identifiable {
    case usage
    case evaluations
    case liveQuota

    var id: String { rawValue }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("BorderCollie")
    }
}
