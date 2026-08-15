import Foundation

actor TrajectoryBackend {
    private let store: UsageAnalyticsStore
    private let usageBackend: UsageAnalyticsBackend

    init(store: UsageAnalyticsStore) {
        self.store = store
        usageBackend = UsageAnalyticsBackend(store: store)
    }

    func refresh() async throws -> UsageImportReport {
        try await usageBackend.refresh()
    }

    func sessions(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        before cursor: TrajectorySessionCursor?,
        limit: Int,
        endingAt date: Date,
        calendar: Calendar
    ) async throws -> TrajectorySessionPage {
        guard (1...200).contains(limit) else {
            throw UsageAnalyticsStoreError.invalidStoredValue(
                column: "trajectory.limit",
                value: String(limit)
            )
        }
        return try await store.trajectorySessions(
            period: period,
            agents: agents,
            before: cursor,
            limit: limit,
            endingAt: date,
            calendar: calendar
        )
    }

    func report(sessionKey: String) async throws -> TrajectorySessionReport? {
        try await store.trajectoryReport(sessionKey: sessionKey)
    }
}
