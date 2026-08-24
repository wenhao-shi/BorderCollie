import Combine
import Foundation

@MainActor
final class UsageTrackerViewModel: ObservableObject {
    @Published private(set) var quota: SubscriptionQuota?
    @Published private(set) var isLoading = false

    private let service: UsageTrackingService
    private var refreshTask: Task<Void, Never>?

    init(service: UsageTrackingService, initialQuota: SubscriptionQuota? = nil) {
        self.service = service
        self.quota = initialQuota
    }

    func refresh() {
        guard !isLoading else {
            return
        }

        isLoading = true

        refreshTask = Task { [service] in
            defer {
                isLoading = false
                refreshTask = nil
            }

            let result = await UsageQuotaQuery.query(service: service)
            guard !Task.isCancelled else {
                return
            }

            switch result {
            case .success(let quota):
                self.quota = quota
            case .failure:
                self.quota = .error(
                    tool: service.toolID,
                    status: .valid,
                    message: "Quota query timed out. Try again in a moment.",
                    now: Date()
                )
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }
}
