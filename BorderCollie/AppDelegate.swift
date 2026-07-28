import AppKit

/// Keeps BorderCollie alive as a menu-bar companion after the main window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hide the Dock icon while the gauge item continues to run.
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .borderCollieShowMainWindow, object: nil)
        }
        return true
    }
}

extension Notification.Name {
    static let borderCollieShowMainWindow = Notification.Name("borderCollieShowMainWindow")
}

enum BorderCollieAppActivation {
    @MainActor
    static func revealDockIcon() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func quit() {
        NSApp.terminate(nil)
    }
}
