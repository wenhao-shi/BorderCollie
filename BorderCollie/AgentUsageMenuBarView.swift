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
            Label("Usage remaining", systemImage: "gauge")
                .font(.headline)

            Spacer()

            refreshButton
        }
    }

    private var refreshButton: some View {
        Button {
            Task {
                await viewModel.refresh()
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24, height: 24)
                .opacity(viewModel.isRefreshing ? 0.45 : 1)
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isRefreshing)
        .accessibilityLabel("Refresh")
        .help("Refresh")
    }

    private var footerActions: some View {
        VStack(spacing: 2) {
            Button("Show Window") {
                showMainWindow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Quit BorderCollie") {
                BorderCollieAppActivation.quit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    /// Icon on the left, usage on the right. The icon identifies the agent, so
    /// the name is carried only as an accessibility label.
    private func usageRow(_ row: MenuBarUsageRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
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
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

struct AgentUsageMenuBarView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        AgentUsageMenuBarView(viewModel: .preview, runsAutoRefresh: false)
            .previewDisplayName("Menu Bar Usage")
    }
}
