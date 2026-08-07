import SwiftUI

struct ClaudeUsageView: View {
    private let viewModel: UsageTrackerViewModel
    private let runsAutoRefresh: Bool

    @MainActor
    init(viewModel: UsageTrackerViewModel? = nil, runsAutoRefresh: Bool = true) {
        self.viewModel = viewModel ?? UsageTrackerViewModel(service: ClaudeQuotaService.live)
        self.runsAutoRefresh = runsAutoRefresh
    }

    var body: some View {
        UsageTrackerView(
            title: "Claude Code",
            icon: .claudeCode,
            viewModel: viewModel,
            queryingTitle: "Querying Claude Code quota...",
            readyMessage: "Refresh to read Claude Code OAuth credentials and query current usage.",
            notFoundTitle: "No Claude Code credentials found",
            notFoundMessage: "Sign in with Claude Code, then refresh.",
            parseErrorTitle: "Could not read Claude Code credentials",
            expiredTitle: "Claude Code credentials need refresh",
            expiredMessage: "Sign in with Claude Code again, then refresh.",
            genericErrorMessage: "The Claude Code usage API did not return a usable response.",
            runsAutoRefresh: runsAutoRefresh,
            autoRefreshInterval: .seconds(Int(ClaudeUsageRequestGate.minimumRefreshInterval)),
            usageLimits: ClaudeUsageLimitDisplay.usageLimits
        )
    }
}

struct ClaudeUsageView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        ClaudeUsageView(
            viewModel: UsageTrackerViewModel(
                service: ClaudeQuotaService.live,
                initialQuota: .previewClaudeUsage
            ),
            runsAutoRefresh: false
        )
        .previewDisplayName("Claude Code Usage")
    }
}

private extension SubscriptionQuota {
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
