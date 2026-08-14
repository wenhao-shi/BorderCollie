import AppKit
import SwiftUI

struct AgentUsageMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: MenuBarUsageViewModel

    private let runsAutoRefresh: Bool

    @MainActor
    init(viewModel: MenuBarUsageViewModel? = nil, runsAutoRefresh: Bool = true) {
        _viewModel = StateObject(wrappedValue: viewModel ?? MenuBarUsageViewModel())
        self.runsAutoRefresh = runsAutoRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 8) {
                ForEach(viewModel.rows) { row in
                    usageRow(row)
                }
            }

            Divider()

            footerActions
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
        .task {
            await runAutoRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .borderCollieShowMainWindow)) { _ in
            showMainWindow()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Usage consumed", systemImage: "gauge")
                .font(.headline)

            Spacer()

            refreshButton
        }
    }

    /// Swaps to a `ProgressView` while refreshing, matching the three other
    /// refresh controls in the app. It used to dim the icon to 45% instead.
    private var refreshButton: some View {
        Button {
            Task {
                await viewModel.refresh()
            }
        } label: {
            Group {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isRefreshing)
        .accessibilityLabel("Refresh")
        .help("Refresh")
    }

    /// Hover-highlighted rows rather than tinted borderless buttons, which read
    /// as links in a surface where every other menu-bar extra shows menu items.
    private var footerActions: some View {
        VStack(spacing: 0) {
            MenuBarActionRow(title: "Open BorderCollie", action: showMainWindow)

            MenuBarActionRow(
                title: "Quit BorderCollie",
                shortcutHint: "⌘Q",
                action: BorderCollieAppActivation.quit
            )
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// Icon on the left, usage on the right. The icon identifies the agent, so
    /// the name is carried only as an accessibility label.
    private func usageRow(_ row: MenuBarUsageRow) -> some View {
        HStack(alignment: .center, spacing: UsageDesign.Spacing.medium) {
            AgentIconView(icon: row.icon, size: 28)

            if row.limits.isEmpty {
                Text(row.detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(detailForegroundStyle(for: row.state))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                UsageLimitsGrid(limits: row.limits, font: .caption)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UsageDesign.Spacing.small + 2)
        // `.quaternary` over the popover's own material. `controlBackgroundColor`
        // is the backdrop drawn *behind* controls, and using it here laid an
        // opaque card on top of the material the popover already provides.
        .background(.quaternary, in: UsageDesign.cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title). \(row.detail)")
    }

    @MainActor
    private func showMainWindow() {
        BorderCollieAppActivation.revealDockIcon()
        openWindow(id: AppDelegate.mainWindowID)

        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: Self.isMainWindow) {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private func runAutoRefreshLoop() async {
        guard runsAutoRefresh, !Self.isRunningInXcodePreview else {
            return
        }

        await viewModel.refresh()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            await viewModel.refresh()
        }
    }

    private func detailForegroundStyle(for state: MenuBarUsageRowState) -> AnyShapeStyle {
        switch state {
        case .loading:
            AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        case .success:
            AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case .unavailable:
            AnyShapeStyle(Color.orange)
        }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == AppDelegate.mainWindowID {
            return true
        }
        return window.title == "BorderCollie" && window.canBecomeMain
    }
}

private extension AgentUsageMenuBarView {
    static var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

/// A menu-item row for the window-style menu bar extra: full-width hit target,
/// hover highlight, no tint.
private struct MenuBarActionRow: View {
    let title: String
    var shortcutHint: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcutHint {
                    Text(shortcutHint)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, UsageDesign.Spacing.small)
            .padding(.vertical, 5)
            .background(
                isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: UsageDesign.inlineShape
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct AgentUsageMenuBarView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        AgentUsageMenuBarView(viewModel: .preview, runsAutoRefresh: false)
            .previewDisplayName("Menu Bar Usage")
    }
}
