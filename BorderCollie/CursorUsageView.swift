import SwiftUI

struct CursorUsageView: View {
    private let viewModel: UsageTrackerViewModel
    private let runsAutoRefresh: Bool

    @MainActor
    init(viewModel: UsageTrackerViewModel? = nil, runsAutoRefresh: Bool = true) {
        self.viewModel = viewModel ?? UsageTrackerViewModel(service: CursorQuotaService.live)
        self.runsAutoRefresh = runsAutoRefresh
    }

    var body: some View {
        UsageTrackerView(
            title: "Cursor",
            icon: .cursor,
            viewModel: viewModel,
            queryingTitle: "Querying Cursor quota...",
            readyMessage: "Refresh to read Cursor IDE credentials and query current usage.",
            notFoundTitle: "No Cursor credentials found",
            notFoundMessage: "Sign in to Cursor, then refresh.",
            parseErrorTitle: "Could not read Cursor credentials",
            expiredTitle: "Cursor credentials need refresh",
            expiredMessage: "Sign in to Cursor again, then refresh.",
            genericErrorMessage: "The Cursor usage API did not return a usable response.",
            runsAutoRefresh: runsAutoRefresh,
            usageLimits: CursorUsageLimitDisplay.usageLimits
        )
    }
}

struct CursorUsageView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        CursorUsageView(
            viewModel: UsageTrackerViewModel(
                service: CursorQuotaService.live,
                initialQuota: .previewCursorUsage
            ),
            runsAutoRefresh: false
        )
        .previewDisplayName("Cursor Usage")
    }
}

private extension SubscriptionQuota {
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
}
