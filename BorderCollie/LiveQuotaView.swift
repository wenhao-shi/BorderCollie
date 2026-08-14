import SwiftUI

/// The user-facing copy for one tracker's non-success states.
///
/// Kept beside the tracker descriptor rather than passed as a dozen loose view
/// parameters, which is what the per-provider pages used to do.
struct UsageTrackerCopy: Sendable {
    let querying: String
    let ready: String
    let notFoundTitle: String
    let notFoundMessage: String
    let parseErrorTitle: String
    let expiredTitle: String
    let expiredMessage: String
    let genericError: String
}

/// One live-quota provider: identity, how to query it, how to label its
/// windows, and how often to poll.
struct LiveQuotaTracker: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: AgentIcon
    let service: any UsageTrackingService
    let usageLimits: @Sendable (SubscriptionQuota) -> [UsageLimitDisplay]
    let refreshInterval: Duration
    let copy: UsageTrackerCopy

    static let codex = LiveQuotaTracker(
        id: "codex",
        title: "Codex",
        icon: .codex,
        service: CodexQuotaService.live,
        usageLimits: CodexUsageLimitDisplay.usageLimits,
        refreshInterval: .seconds(30),
        copy: UsageTrackerCopy(
            querying: "Checking Codex usage…",
            ready: "Refresh to check your current Codex usage.",
            notFoundTitle: "Not signed in to Codex",
            notFoundMessage: "Sign in with the Codex CLI, then refresh.",
            parseErrorTitle: "Codex sign-in state could not be read",
            expiredTitle: "Codex sign-in expired",
            expiredMessage: "Sign in with the Codex CLI again, then refresh.",
            genericError: "The remote quota API did not return a usable response."
        )
    )

    static let cursor = LiveQuotaTracker(
        id: "cursor",
        title: "Cursor",
        icon: .cursor,
        service: CursorQuotaService.live,
        usageLimits: CursorUsageLimitDisplay.usageLimits,
        refreshInterval: .seconds(30),
        copy: UsageTrackerCopy(
            querying: "Checking Cursor usage…",
            ready: "Refresh to check your current Cursor usage.",
            notFoundTitle: "Not signed in to Cursor",
            notFoundMessage: "Sign in to Cursor, then refresh.",
            parseErrorTitle: "Cursor sign-in state could not be read",
            expiredTitle: "Cursor sign-in expired",
            expiredMessage: "Sign in to Cursor again, then refresh.",
            genericError: "The Cursor usage API did not return a usable response."
        )
    )

    /// Claude polls at 60 seconds, not 30: its OAuth usage endpoint rate-limits
    /// harder. `ClaudeUsageRequestGate` still gates the actual request.
    static let claudeCode = LiveQuotaTracker(
        id: "claude_code",
        title: "Claude Code",
        icon: .claudeCode,
        service: ClaudeQuotaService.live,
        usageLimits: ClaudeUsageLimitDisplay.usageLimits,
        refreshInterval: .seconds(Int(ClaudeUsageRequestGate.minimumRefreshInterval)),
        copy: UsageTrackerCopy(
            querying: "Checking Claude Code usage…",
            ready: "Refresh to check your current Claude Code usage.",
            notFoundTitle: "Not signed in to Claude Code",
            notFoundMessage: "Sign in with Claude Code, then refresh.",
            parseErrorTitle: "Claude Code sign-in state could not be read",
            expiredTitle: "Claude Code sign-in expired",
            expiredMessage: "Sign in with Claude Code again, then refresh.",
            genericError: "The Claude Code usage API did not return a usable response."
        )
    )

    /// Product order, matching the menu-bar panel.
    static let all: [LiveQuotaTracker] = [.codex, .cursor, .claudeCode]
}

/// Every tracked provider's live quota on one page.
///
/// Each provider keeps its own view model, cadence, and failure state — one
/// provider being signed out or rate-limited must not blank the others — but
/// they share a page, because comparing them was previously three sidebar
/// clicks apart.
struct LiveQuotaView: View {
    @StateObject private var codex: UsageTrackerViewModel
    @StateObject private var cursor: UsageTrackerViewModel
    @StateObject private var claudeCode: UsageTrackerViewModel

    private let runsAutoRefresh: Bool

    @MainActor
    init(runsAutoRefresh: Bool = true) {
        _codex = StateObject(wrappedValue: UsageTrackerViewModel(service: LiveQuotaTracker.codex.service))
        _cursor = StateObject(wrappedValue: UsageTrackerViewModel(service: LiveQuotaTracker.cursor.service))
        _claudeCode = StateObject(wrappedValue: UsageTrackerViewModel(service: LiveQuotaTracker.claudeCode.service))
        self.runsAutoRefresh = runsAutoRefresh
    }

    @MainActor
    init(
        codex: UsageTrackerViewModel,
        cursor: UsageTrackerViewModel,
        claudeCode: UsageTrackerViewModel,
        runsAutoRefresh: Bool = false
    ) {
        _codex = StateObject(wrappedValue: codex)
        _cursor = StateObject(wrappedValue: cursor)
        _claudeCode = StateObject(wrappedValue: claudeCode)
        self.runsAutoRefresh = runsAutoRefresh
    }

    var body: some View {
        Form {
            trackerSection(.codex, viewModel: codex)
            trackerSection(.cursor, viewModel: cursor)
            trackerSection(.claudeCode, viewModel: claudeCode)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Live quota")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        // One loop per provider, so Claude's slower cadence does not drag the
        // other two and a slow provider cannot delay its neighbours' polls.
        .task { await autoRefresh(codex, every: LiveQuotaTracker.codex.refreshInterval) }
        .task { await autoRefresh(cursor, every: LiveQuotaTracker.cursor.refreshInterval) }
        .task { await autoRefresh(claudeCode, every: LiveQuotaTracker.claudeCode.refreshInterval) }
    }

    private var isRefreshing: Bool {
        codex.isLoading || cursor.isLoading || claudeCode.isLoading
    }

    private func refreshAll() {
        codex.refresh()
        cursor.refresh()
        claudeCode.refresh()
    }

    @ViewBuilder
    private func trackerSection(
        _ tracker: LiveQuotaTracker,
        viewModel: UsageTrackerViewModel
    ) -> some View {
        Section {
            trackerContent(tracker, viewModel: viewModel)
        } header: {
            Label {
                Text(tracker.title)
            } icon: {
                AgentIconView(icon: tracker.icon, size: 16)
            }
            .font(.headline)
        } footer: {
            trackerFooter(viewModel)
        }
    }

    @ViewBuilder
    private func trackerContent(
        _ tracker: LiveQuotaTracker,
        viewModel: UsageTrackerViewModel
    ) -> some View {
        if viewModel.isLoading, viewModel.quota == nil {
            HStack(spacing: UsageDesign.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text(tracker.copy.querying)
                    .foregroundStyle(.secondary)
            }
        } else if let quota = viewModel.quota {
            switch quota.credentialStatus {
            case .notFound:
                unavailableRow(
                    title: tracker.copy.notFoundTitle,
                    message: tracker.copy.notFoundMessage,
                    systemImage: "person.badge.key",
                    viewModel: viewModel
                )
            case .parseError:
                unavailableRow(
                    title: tracker.copy.parseErrorTitle,
                    message: quota.credentialMessage ?? "The local sign-in state could not be read.",
                    systemImage: "exclamationmark.triangle",
                    viewModel: viewModel
                )
            case .expired where !quota.success:
                unavailableRow(
                    title: tracker.copy.expiredTitle,
                    message: quota.error ?? tracker.copy.expiredMessage,
                    systemImage: "clock.badge.exclamationmark",
                    viewModel: viewModel
                )
            case _ where !quota.success:
                unavailableRow(
                    title: "Quota query failed",
                    message: quota.error ?? tracker.copy.genericError,
                    systemImage: "exclamationmark.triangle",
                    viewModel: viewModel
                )
            default:
                ForEach(tracker.usageLimits(quota)) { limit in
                    limitRow(limit)
                }
            }
        } else {
            unavailableRow(
                title: "Ready to query",
                message: tracker.copy.ready,
                systemImage: "gauge.with.dots.needle.bottom.50percent",
                viewModel: viewModel
            )
        }
    }

    @ViewBuilder
    private func trackerFooter(_ viewModel: UsageTrackerViewModel) -> some View {
        if let quota = viewModel.quota, quota.success {
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

    /// Per-provider recovery. The toolbar's Refresh covers all three, but a
    /// provider that needs attention offers its own retry where the message is.
    private func unavailableRow(
        title: String,
        message: String,
        systemImage: String,
        viewModel: UsageTrackerViewModel
    ) -> some View {
        HStack(alignment: .top, spacing: UsageDesign.Spacing.medium) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: UsageDesign.Spacing.medium)

            Button("Refresh") {
                viewModel.refresh()
            }
            .disabled(viewModel.isLoading)
        }
        .padding(.vertical, UsageDesign.Spacing.tight)
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func autoRefresh(_ viewModel: UsageTrackerViewModel, every interval: Duration) async {
        guard runsAutoRefresh, !Self.isRunningInXcodePreview else {
            return
        }

        viewModel.refresh()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            viewModel.refresh()
        }
    }
}

private extension LiveQuotaView {
    static var isRunningInXcodePreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

struct LiveQuotaView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        NavigationStack {
            LiveQuotaView(
                codex: UsageTrackerViewModel(
                    service: LiveQuotaTracker.codex.service,
                    initialQuota: .previewCodexUsage
                ),
                cursor: UsageTrackerViewModel(
                    service: LiveQuotaTracker.cursor.service,
                    initialQuota: .previewCursorUsage
                ),
                claudeCode: UsageTrackerViewModel(
                    service: LiveQuotaTracker.claudeCode.service,
                    initialQuota: .previewClaudeUsage
                )
            )
        }
        .frame(width: 900, height: 700)
        .previewDisplayName("Live quota")
    }
}

private extension SubscriptionQuota {
    static var previewCodexUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 80, resetsAt: "2026-07-03T02:24:00Z"),
                QuotaTier(name: "seven_day", utilization: 40, resetsAt: "2026-07-07T12:00:00Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }

    static var previewCursorUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "cursor",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: CursorUsageLimitKind.autoComposer.rawValue, utilization: 1, resetsAt: "2026-07-30T03:12:17Z"),
                QuotaTier(name: CursorUsageLimitKind.api.rawValue, utilization: 0, resetsAt: "2026-07-30T03:12:17Z"),
            ],
            extraUsage: "You've used 1% of your included usage",
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }

    static var previewClaudeUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "claude_code",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: ClaudeUsageLimitKind.fiveHour.rawValue, utilization: 48, resetsAt: "2026-07-27T20:00:00Z"),
                QuotaTier(name: ClaudeUsageLimitKind.week.rawValue, utilization: 64, resetsAt: "2026-08-01T06:00:00Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }
}
