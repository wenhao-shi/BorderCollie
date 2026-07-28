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

        MenuBarExtra("BorderCollie", systemImage: "gauge") {
            AgentUsageMenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
