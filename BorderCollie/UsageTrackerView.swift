import SwiftUI

struct UsageTrackerView: View {
    @StateObject private var viewModel: UsageTrackerViewModel

    private let title: String
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
        VStack(alignment: .leading, spacing: 18) {
            quotaContent
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 320, alignment: .topLeading)
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
                unavailableState(title: notFoundTitle, message: notFoundMessage)
            case .parseError:
                unavailableState(
                    title: parseErrorTitle,
                    message: quota.credentialMessage ?? "The local auth state could not be parsed."
                )
            case .expired where !quota.success:
                unavailableState(
                    title: expiredTitle,
                    message: quota.error ?? expiredMessage
                )
            case _ where !quota.success:
                unavailableState(
                    title: "Quota query failed",
                    message: quota.error ?? genericErrorMessage
                )
            default:
                quotaSuccessView(quota)
            }
        } else {
            unavailableState(title: "Ready to query", message: readyMessage)
        }
    }

    private func quotaSuccessView(_ quota: SubscriptionQuota) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            usageRemainingSection(quota)

            if let queriedAt = quota.queriedAt {
                Text("Updated at \(Date(timeIntervalSince1970: TimeInterval(queriedAt) / 1_000), style: .time)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func usageRemainingSection(_ quota: SubscriptionQuota) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)

                Text("Usage remaining")
                    .font(.title3)
                    .fontWeight(.medium)
            }

            VStack(spacing: 8) {
                ForEach(usageLimits(quota)) { limit in
                    usageRemainingRow(limit)
                }
            }
            .padding(.leading, 36)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func usageRemainingRow(_ limit: UsageLimitDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 18) {
                Text(limit.title)
                    .font(.body)
                    .fontWeight(.medium)

                Spacer()

                Text(limit.percentageText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(limit.tier == nil ? .tertiary : .secondary)

                Text(limit.resetText() ?? "--")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }

            ProgressView(value: limit.remainingPercentage, total: 100)
                .controlSize(.small)
        }
    }

    private func unavailableState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension UsageTrackerView {
    static var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
