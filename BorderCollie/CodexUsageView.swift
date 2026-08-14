import SwiftUI

struct CodexUsageView: View {
    private let viewModel: UsageTrackerViewModel
    private let runsAutoRefresh: Bool

    @MainActor
    init(viewModel: UsageTrackerViewModel? = nil, runsAutoRefresh: Bool = true) {
        self.viewModel = viewModel ?? UsageTrackerViewModel(service: CodexQuotaService.live)
        self.runsAutoRefresh = runsAutoRefresh
    }

    var body: some View {
        UsageTrackerView(
            title: "Codex",
            icon: .codex,
            viewModel: viewModel,
            queryingTitle: "Checking Codex usage…",
            readyMessage: "Refresh to check your current Codex usage.",
            notFoundTitle: "Not signed in to Codex",
            notFoundMessage: "Sign in with the Codex CLI, then refresh.",
            parseErrorTitle: "Codex sign-in state could not be read",
            expiredTitle: "Codex sign-in expired",
            expiredMessage: "Sign in with the Codex CLI again, then refresh.",
            genericErrorMessage: "The remote quota API did not return a usable response.",
            runsAutoRefresh: runsAutoRefresh,
            usageLimits: CodexUsageLimitDisplay.usageLimits
        )
    }
}

struct CodexUsageView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        CodexUsageView(
            viewModel: UsageTrackerViewModel(
                service: CodexQuotaService.live,
                initialQuota: .previewCodexUsage
            ),
            runsAutoRefresh: false
        )
        .previewDisplayName("Codex Usage")
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
}
