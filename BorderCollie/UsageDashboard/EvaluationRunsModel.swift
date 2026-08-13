import Combine
import Foundation

@MainActor
final class EvaluationRunsModel: ObservableObject {
    @Published private(set) var runs: [EvaluationRun] = []
    @Published private(set) var report: UsageEvaluationReport?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var importIssues: [UsageImportIssue] = []

    private let backend: EvaluationRunsBackend?
    private var didLoad = false
    private var requestRevision = 0

    private init(backend: EvaluationRunsBackend?, errorMessage: String? = nil) {
        self.backend = backend
        self.errorMessage = errorMessage
    }

    static func live() -> EvaluationRunsModel {
        do {
            let store = try UsageAnalyticsStore()
            return EvaluationRunsModel(backend: EvaluationRunsBackend(store: store))
        } catch {
            return EvaluationRunsModel(
                backend: nil,
                errorMessage: "The local evaluation database could not be opened (\(String(describing: type(of: error))))."
            )
        }
    }

    var canStart: Bool {
        backend != nil && !runs.contains(where: \.isActive)
    }

    func loadInitially() async {
        guard !didLoad else { return }
        didLoad = true
        await refreshUsage()
    }

    func refreshUsage(selectedRunID: String? = nil) async {
        guard let backend, !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let importReport = try await backend.refreshUsage()
            importIssues = importReport.agents.flatMap(\.issues)
            runs = try await backend.runs()
            if let selectedRunID {
                await loadReport(runID: selectedRunID)
            }
        } catch {
            errorMessage = "Evaluation refresh failed (\(String(describing: type(of: error))))."
            await reloadRuns()
        }
    }

    func reloadRuns() async {
        guard let backend else { return }
        do {
            runs = try await backend.runs()
        } catch {
            errorMessage = "Evaluation runs could not be loaded (\(String(describing: type(of: error))))."
        }
    }

    func loadReport(runID: String?) async {
        guard let backend, let runID else {
            report = nil
            return
        }
        requestRevision += 1
        let revision = requestRevision
        isLoading = true
        defer {
            if revision == requestRevision { isLoading = false }
        }
        do {
            let loaded = try await backend.report(runID: runID)
            guard revision == requestRevision else { return }
            report = loaded
            errorMessage = nil
        } catch {
            guard revision == requestRevision else { return }
            errorMessage = "The evaluation report could not be loaded (\(String(describing: type(of: error))))."
        }
    }

    func start(name: String) async -> String? {
        guard let backend else { return nil }
        do {
            let run = try await backend.start(name: name)
            runs = try await backend.runs()
            report = try await backend.report(runID: run.id)
            errorMessage = nil
            return run.id
        } catch {
            errorMessage = "The evaluation could not be started (\(String(describing: type(of: error))))."
            return nil
        }
    }

    func createPast(name: String, interval: DateInterval) async -> String? {
        guard let backend else { return nil }
        do {
            let run = try await backend.createPast(name: name, interval: interval)
            runs = try await backend.runs()
            report = try await backend.report(runID: run.id)
            errorMessage = nil
            return run.id
        } catch {
            errorMessage = "The past evaluation could not be created (\(String(describing: type(of: error))))."
            return nil
        }
    }

    func stop(runID: String) async {
        guard let backend else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await backend.stop(id: runID)
            runs = try await backend.runs()
            report = try await backend.report(runID: runID)
            errorMessage = nil
        } catch {
            let message = "The evaluation stopped, but its usage refresh did not complete. Its saved state was preserved (\(String(describing: type(of: error))))."
            await reloadRuns()
            await loadReport(runID: runID)
            errorMessage = message
        }
    }

    func setSession(runID: String, sessionKey: String, isSelected: Bool) async {
        guard let backend, let report, report.run.id == runID else { return }
        var selected = report.selectedSessionKeys
        if isSelected {
            selected.insert(sessionKey)
        } else {
            selected.remove(sessionKey)
        }
        do {
            try await backend.replaceSessionKeys(runID: runID, sessionKeys: selected)
            self.report = try await backend.report(runID: runID)
            errorMessage = nil
        } catch {
            errorMessage = "The session selection could not be saved (\(String(describing: type(of: error))))."
        }
    }

    func delete(runID: String) async {
        guard let backend else { return }
        do {
            try await backend.delete(runID: runID)
            runs = try await backend.runs()
            if report?.run.id == runID { report = nil }
            errorMessage = nil
        } catch {
            errorMessage = "The evaluation could not be deleted (\(String(describing: type(of: error))))."
        }
    }
}
