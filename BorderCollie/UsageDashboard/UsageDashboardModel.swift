import Combine
import Foundation

@MainActor
final class UsageDashboardModel: ObservableObject {
    @Published private(set) var aggregate: UsageAggregate?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingAggregate = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var importIssues: [UsageImportIssue] = []
    @Published private(set) var lastSuccessfulImport: Date?

    private let backend: UsageAnalyticsBackend?
    private var aggregateRequestRevision = 0
    private var didAttemptInitialLoad = false

    private init(
        backend: UsageAnalyticsBackend?,
        aggregate: UsageAggregate? = nil,
        errorMessage: String? = nil,
        lastSuccessfulImport: Date? = nil
    ) {
        self.backend = backend
        self.aggregate = aggregate
        self.errorMessage = errorMessage
        self.lastSuccessfulImport = lastSuccessfulImport
    }

    static func live() -> UsageDashboardModel {
        do {
            let store = try UsageAnalyticsStore()
            return UsageDashboardModel(backend: UsageAnalyticsBackend(store: store))
        } catch {
            return UsageDashboardModel(
                backend: nil,
                errorMessage: "The local usage index could not be opened (\(String(describing: type(of: error))))."
            )
        }
    }

    static func preview(aggregate: UsageAggregate) -> UsageDashboardModel {
        UsageDashboardModel(
            backend: nil,
            aggregate: aggregate,
            lastSuccessfulImport: Date(timeIntervalSince1970: 1_786_470_000)
        )
    }

    var canRefresh: Bool {
        backend != nil
    }

    func loadInitially(range: UsageDateRange, agents: Set<UsageAgent>) async {
        guard !didAttemptInitialLoad else { return }
        didAttemptInitialLoad = true
        await refresh(range: range, agents: agents)
    }

    func refresh(range: UsageDateRange, agents: Set<UsageAgent>) async {
        guard let backend, !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        aggregateRequestRevision += 1
        let revision = aggregateRequestRevision

        defer { isRefreshing = false }

        do {
            let report = try await backend.refresh()
            importIssues = report.agents.flatMap(\.issues)
            lastSuccessfulImport = Date(
                timeIntervalSince1970: TimeInterval(report.finishedAtMilliseconds) / 1_000
            )
            let refreshed = try await backend.aggregate(range: range, agents: agents)
            guard revision == aggregateRequestRevision else { return }
            aggregate = refreshed
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Usage refresh failed (\(String(describing: type(of: error))))."
        }
    }

    func loadAggregate(range: UsageDateRange, agents: Set<UsageAgent>) async {
        guard let backend else { return }
        aggregateRequestRevision += 1
        let revision = aggregateRequestRevision
        let previousAggregate = aggregate
        aggregate = nil
        isLoadingAggregate = true
        defer {
            if revision == aggregateRequestRevision {
                isLoadingAggregate = false
            }
        }

        do {
            let refreshed = try await backend.aggregate(range: range, agents: agents)
            guard revision == aggregateRequestRevision else { return }
            aggregate = refreshed
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == aggregateRequestRevision else { return }
            aggregate = previousAggregate
            errorMessage = "The selected usage range could not be loaded (\(String(describing: type(of: error))))."
        }
    }
}
