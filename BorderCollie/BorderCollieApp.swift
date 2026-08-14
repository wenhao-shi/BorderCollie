//
//  BorderCollieApp.swift
//  BorderCollie
//
//  Created by Mason on 7/2/26.
//

import SwiftUI

@main
struct BorderCollieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("BorderCollie", id: AppDelegate.mainWindowID) {
            ContentView()
        }
        // One size contract for the whole window. Previously each detail view
        // declared its own `minWidth` (900, 980, 520), so selecting a sidebar
        // item rewrote the window's minimum size.
        .defaultSize(width: 1_100, height: 740)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            AgentUsageMenuBarView()
        } label: {
            Image(nsImage: .borderCollieMenuBarIcon)
                .accessibilityLabel("BorderCollie")
        }
        .menuBarExtraStyle(.window)
    }
}
