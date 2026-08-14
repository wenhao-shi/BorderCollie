import SwiftUI

struct UsageTrackerView: View {
    @StateObject private var viewModel: UsageTrackerViewModel

    private let title: String
    private let icon: AgentIcon
    private let queryingTitle: String
    private let readyMessage: String
    private let notFoundTitle: String
    private let notFoundMessage: String
    private let parseErrorTitle: String
    private let expiredTitle: String
    private let expiredMessage: String
    private let genericErrorMessage: String
    private let runsAutoRefresh: Bool
    private let autoRefreshInterval: Duration
    private let usageLimits: (SubscriptionQuota) -> [UsageLimitDisplay]

    @MainActor
    init(
        title: String,
        icon: AgentIcon,
        viewModel: UsageTrackerViewModel,
        queryingTitle: String,
        readyMessage: String,
        notFoundTitle: String,
        notFoundMessage: String,
        parseErrorTitle: String,
        expiredTitle: String,
        expiredMessage: String,
        genericErrorMessage: String,
        runsAutoRefresh: Bool = true,
        autoRefreshInterval: Duration = .seconds(30),
        usageLimits: @escaping (SubscriptionQuota) -> [UsageLimitDisplay]
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.title = title
        self.icon = icon
        self.queryingTitle = queryingTitle
        self.readyMessage = readyMessage
        self.notFoundTitle = notFoundTitle
        self.notFoundMessage = notFoundMessage
        self.parseErrorTitle = parseErrorTitle
        self.expiredTitle = expiredTitle
        self.expiredMessage = expiredMessage
        self.genericErrorMessage = genericErrorMessage
        self.runsAutoRefresh = runsAutoRefresh
        self.autoRefreshInterval = autoRefreshInterval
        self.usageLimits = usageLimits
    }

    var body: some View {
        quotaContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .task {
                await runAutoRefreshLoop()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    refreshToolbarButton
                }
            }
    }

    private var refreshToolbarButton: some View {
        Button {
            viewModel.refresh()
        } label: {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(viewModel.isLoading)
        .keyboardShortcut("r", modifiers: .command)
    }

    @MainActor
    private func runAutoRefreshLoop() async {
        guard runsAutoRefresh, !Self.isRunningInXcodePreview else {
            return
        }

        viewModel.refresh()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: autoRefreshInterval)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            viewModel.refresh()
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if viewModel.isLoading, viewModel.quota == nil {
            ProgressView(queryingTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let quota = viewModel.quota {
            switch quota.credentialStatus {
            case .notFound:
                unavailableState(
                    title: notFoundTitle,
                    message: notFoundMessage,
                    systemImage: "person.badge.key"
                )
            case .parseError:
                unavailableState(
                    title: parseErrorTitle,
                    message: quota.credentialMessage ?? "The local sign-in state could not be read.",
                    systemImage: "exclamationmark.triangle"
                )
            case .expired where !quota.success:
                unavailableState(
                    title: expiredTitle,
                    message: quota.error ?? expiredMessage,
                    systemImage: "clock.badge.exclamationmark"
                )
            case _ where !quota.success:
                unavailableState(
                    title: "Quota query failed",
                    message: quota.error ?? genericErrorMessage,
                    systemImage: "exclamationmark.triangle"
                )
            default:
                quotaSuccessView(quota)
            }
        } else {
            unavailableState(
                title: "Ready to query",
                message: readyMessage,
                systemImage: "gauge.with.dots.needle.bottom.50percent"
            )
        }
    }

    /// A grouped `Form` rather than a fixed-width card: this pane is as wide as
    /// the Usage dashboard's, and a 520-point box pinned to its top-left corner
    /// read as an unfinished screen.
    private func quotaSuccessView(_ quota: SubscriptionQuota) -> some View {
        Form {
            Section {
                ForEach(usageLimits(quota)) { limit in
                    limitRow(limit)
                }
            } header: {
                Label {
                    Text(title)
                } icon: {
                    AgentIconView(icon: icon, size: 16)
                }
                .font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: UsageDesign.Spacing.tight) {
                    if let extraUsage = quota.extraUsage {
                        Label(extraUsage, systemImage: "creditcard")
                    }
                    if let queriedAt = quota.queriedAt {
                        Text("Updated at \(Date(timeIntervalSince1970: TimeInterval(queriedAt) / 1_000), style: .time)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, UsageDesign.Spacing.tight)
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("\(title) usage consumed")
    }

    private func limitRow(_ limit: UsageLimitDisplay) -> some View {
        VStack(alignment: .leading, spacing: UsageDesign.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: UsageDesign.Spacing.small) {
                Text(limit.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: UsageDesign.Spacing.medium)

                Text(limit.percentageText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.28), value: limit.usedPercentage)
                    .foregroundStyle(limit.tier == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))

                Text(UsageLimitDisplay.resetLabel(for: limit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 104, alignment: .leading)
            }

            ProgressView(value: limit.usedPercentage, total: 100)
                .tint(limit.usedPercentage.quotaTint)
                .animation(.smooth(duration: 0.28), value: limit.usedPercentage)
        }
        .padding(.vertical, UsageDesign.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(limit.title)
        .accessibilityValue("\(limit.percentageText) consumed, \(UsageLimitDisplay.resetLabel(for: limit))")
    }

    /// Native empty states carry a way out, so every one of these offers the
    /// retry the message asks for.
    private func unavailableState(title: String, message: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Refresh") {
                viewModel.refresh()
            }
            .disabled(viewModel.isLoading)
        }
    }
}

private extension UsageTrackerView {
    static var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
