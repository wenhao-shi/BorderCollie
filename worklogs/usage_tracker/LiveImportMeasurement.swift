import Foundation

@main
struct LiveImportMeasurement {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw MeasurementError.missingDatabasePath
        }
        let store = try UsageAnalyticsStore(databaseURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let backend = UsageAnalyticsBackend(store: store)

        let coldStart = Date()
        let cold = try await backend.refresh()
        let coldMilliseconds = Int(Date().timeIntervalSince(coldStart) * 1_000)
        let coldCount = try await store.eventCount()

        let warmStart = Date()
        let warm = try await backend.refresh()
        let warmMilliseconds = Int(Date().timeIntervalSince(warmStart) * 1_000)
        let warmCount = try await store.eventCount()

        print("cold_ms=\(coldMilliseconds) events=\(coldCount) \(summary(cold))")
        print("warm_ms=\(warmMilliseconds) events=\(warmCount) \(summary(warm))")
    }

    private static func summary(_ report: UsageImportReport) -> String {
        report.agents.map {
            "\($0.agent.rawValue):imported=\($0.importedEvents),issues=\($0.issues.count)"
        }.joined(separator: " ")
    }
}

enum MeasurementError: Error {
    case missingDatabasePath
}
