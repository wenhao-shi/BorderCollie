import Combine
import Foundation

@MainActor
final class TrajectoryModel: ObservableObject {
    @Published private(set) var sessions: [TrajectorySessionSummary] = []
    @Published private(set) var nextCursor: TrajectorySessionCursor?
    @Published private(set) var report: TrajectorySessionReport?
    @Published private(set) var selectedSessionKey: String?
    @Published private(set) var selectedRecordID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEarlier = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var importIssues: [UsageImportIssue] = []
    @Published private(set) var lastSuccessfulImport: Date?

    private let backend: TrajectoryBackend?
    private let previewReport: TrajectorySessionReport?
    private var didLoadInitially = false
    private var pageRevision = 0
    private var reportRevision = 0

    init(
        backend: TrajectoryBackend?,
        previewReport: TrajectorySessionReport? = nil
    ) {
        self.backend = backend
        self.previewReport = previewReport
        if let previewReport {
            sessions = [previewReport.summary]
            report = previewReport
        }
    }

    static func live() -> TrajectoryModel {
        do {
            let store = try UsageAnalyticsStore()
            return TrajectoryModel(backend: TrajectoryBackend(store: store))
        } catch {
            return TrajectoryModel(backend: nil)
        }
    }

    static func preview(report: TrajectorySessionReport) -> TrajectoryModel {
        TrajectoryModel(backend: nil, previewReport: report)
    }

    var canRefresh: Bool { backend != nil }
    var hasMoreSessions: Bool { nextCursor != nil }

    func loadInitially(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) async {
        guard !didLoadInitially else { return }
        didLoadInitially = true
        if backend == nil {
            if let previewReport {
                sessions = [previewReport.summary]
                report = previewReport
            }
            return
        }
        await refresh(period: period, agents: agents, endingAt: date, calendar: calendar)
    }

    func refresh(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) async {
        guard let backend, !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let importReport = try await backend.refresh()
            importIssues = importReport.agents.flatMap(\.issues)
            lastSuccessfulImport = Date(
                timeIntervalSince1970: TimeInterval(importReport.finishedAtMilliseconds) / 1_000
            )
            await loadPage(
                period: period,
                agents: agents,
                endingAt: date,
                calendar: calendar,
                replacing: true
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Trajectory refresh failed; the last indexed sessions were preserved."
        }
    }

    func loadPage(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        endingAt date: Date = Date(),
        calendar: Calendar = .current,
        replacing: Bool = false
    ) async {
        guard let backend else { return }
        if replacing {
            pageRevision += 1
        }
        let revision = pageRevision
        if replacing {
            isLoading = true
            nextCursor = nil
        } else {
            guard !isLoadingEarlier, let nextCursor else { return }
            isLoadingEarlier = true
            defer {
                if revision == pageRevision { isLoadingEarlier = false }
            }
            do {
                let page = try await backend.sessions(
                    period: period,
                    agents: agents,
                    before: nextCursor,
                    limit: 200,
                    endingAt: date,
                    calendar: calendar
                )
                guard revision == pageRevision else { return }
                sessions.append(contentsOf: page.sessions.filter { new in !sessions.contains { $0.id == new.id } })
                self.nextCursor = page.nextCursor
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Earlier trajectory sessions could not be loaded."
            }
            return
        }

        defer {
            if revision == pageRevision { isLoading = false }
        }
        do {
            let page = try await backend.sessions(
                period: period,
                agents: agents,
                before: nil,
                limit: 200,
                endingAt: date,
                calendar: calendar
            )
            guard revision == pageRevision else { return }
            sessions = page.sessions
            nextCursor = page.nextCursor
            if let selectedSessionKey,
               !sessions.contains(where: { $0.sessionKey == selectedSessionKey }) {
                reportRevision += 1
                self.selectedSessionKey = nil
                selectedRecordID = nil
                report = nil
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Trajectory sessions could not be loaded; the last indexed sessions were preserved."
        }
    }

    func loadEarlier(
        period: TrajectoryPeriod,
        agents: Set<UsageAgent>,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) async {
        await loadPage(period: period, agents: agents, endingAt: date, calendar: calendar)
    }

    func selectSession(_ sessionKey: String?) async {
        reportRevision += 1
        let revision = reportRevision
        selectedSessionKey = sessionKey
        selectedRecordID = nil
        report = nil
        errorMessage = nil
        guard let sessionKey else {
            return
        }
        if let previewReport, previewReport.summary.sessionKey == sessionKey {
            report = previewReport
            return
        }
        guard let backend else { return }
        isLoading = true
        defer {
            if revision == reportRevision { isLoading = false }
        }
        do {
            let loaded = try await backend.report(sessionKey: sessionKey)
            guard revision == reportRevision else { return }
            report = loaded
            errorMessage = loaded == nil ? "The selected session has no indexed metadata." : nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == reportRevision else { return }
            errorMessage = "The selected trajectory could not be loaded."
        }
    }

    func selectRecord(_ recordID: String?) {
        selectedRecordID = recordID
    }

    func projection(
        mode: TrajectoryTimeMode = .order,
        collapsedRecordIDs: Set<String> = []
    ) -> TrajectoryProjectionResult? {
        guard let report else { return nil }
        return TrajectoryProjection.make(
            report: report,
            mode: mode,
            collapsedRecordIDs: collapsedRecordIDs
        )
    }

}
