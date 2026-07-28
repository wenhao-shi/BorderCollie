import Combine
import Foundation

enum MenuBarUsageRowState: Equatable, Sendable {
    case loading
    case success
    case unavailable
}

struct MenuBarUsageRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: MenuBarUsageRowState
}

struct MenuBarUsageAgent: Identifiable, Sendable {
    let id: String
    let title: String
    let service: any UsageTrackingService
    let compactSummary: @Sendable (SubscriptionQuota) -> String

    static func codex(service: any UsageTrackingService = CodexQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "codex",
            title: "Codex",
            service: service,
            compactSummary: CodexUsageLimitDisplay.compactSummary
        )
    }

    static func cursor(service: any UsageTrackingService = CursorQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "cursor",
            title: "Cursor",
            service: service,
            compactSummary: CursorUsageLimitDisplay.compactSummary
        )
    }

    static func claudeCode(service: any UsageTrackingService = ClaudeQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "claude_code",
            title: "Claude Code",
            service: service,
            compactSummary: ClaudeUsageLimitDisplay.compactSummary
        )
    }
}

@MainActor
final class MenuBarUsageViewModel: ObservableObject {
    @Published private(set) var rows: [MenuBarUsageRow]
    @Published private(set) var isRefreshing = false

    private let agents: [MenuBarUsageAgent]

    init(
        agents: [MenuBarUsageAgent] = [
            .codex(),
            .cursor(),
            .claudeCode(),
        ],
        initialRows: [MenuBarUsageRow]? = nil
    ) {
        self.agents = agents
        self.rows = initialRows ?? agents.map(Self.loadingRow(for:))
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        rows = await Self.queryRows(for: agents)
    }

    private nonisolated static func queryRows(for agents: [MenuBarUsageAgent]) async -> [MenuBarUsageRow] {
        await withTaskGroup(of: (Int, MenuBarUsageRow).self) { group in
            for (index, agent) in agents.enumerated() {
                group.addTask {
                    let result = await UsageQuotaQuery.query(service: agent.service)
                    return (index, Self.row(for: agent, result: result))
                }
            }

            var indexedRows: [(Int, MenuBarUsageRow)] = []
            for await row in group {
                indexedRows.append(row)
            }

            return indexedRows
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private nonisolated static func row(
        for agent: MenuBarUsageAgent,
        result: Result<SubscriptionQuota, UsageQuotaQueryError>
    ) -> MenuBarUsageRow {
        switch result {
        case .success(let quota) where quota.success:
            MenuBarUsageRow(
                id: agent.id,
                title: agent.title,
                detail: agent.compactSummary(quota),
                state: .success
            )
        case .success(let quota):
            MenuBarUsageRow(
                id: agent.id,
                title: agent.title,
                detail: unavailableText(for: quota),
                state: .unavailable
            )
        case .failure(.timedOut):
            MenuBarUsageRow(
                id: agent.id,
                title: agent.title,
                detail: "Timed out",
                state: .unavailable
            )
        }
    }

    private nonisolated static func unavailableText(for quota: SubscriptionQuota) -> String {
        switch quota.credentialStatus {
        case .notFound:
            "Sign in required"
        case .expired:
            "Sign in again"
        case .parseError:
            "Credential issue"
        case .valid:
            "Query failed"
        }
    }

    private nonisolated static func loadingRow(for agent: MenuBarUsageAgent) -> MenuBarUsageRow {
        MenuBarUsageRow(
            id: agent.id,
            title: agent.title,
            detail: "Loading...",
            state: .loading
        )
    }
}

private struct StaticUsageTrackingService: UsageTrackingService {
    let toolID: String
    let quota: SubscriptionQuota

    func getSubscriptionQuota() async -> SubscriptionQuota {
        quota
    }
}

extension MenuBarUsageViewModel {
    static var preview: MenuBarUsageViewModel {
        MenuBarUsageViewModel(
            agents: [
                .codex(service: StaticUsageTrackingService(toolID: "codex", quota: .previewMenuBarCodexUsage)),
                .cursor(service: StaticUsageTrackingService(toolID: "cursor", quota: .previewMenuBarCursorUsage)),
                .claudeCode(service: StaticUsageTrackingService(toolID: "claude_code", quota: .previewMenuBarClaudeUsage)),
            ],
            initialRows: [
                MenuBarUsageRow(id: "codex", title: "Codex", detail: "5h: 80% | 7d: 90%", state: .success),
                MenuBarUsageRow(id: "cursor", title: "Cursor", detail: "Auto: 95% | API: 60%", state: .success),
                MenuBarUsageRow(id: "claude_code", title: "Claude Code", detail: "5h: 52% | 7d: 36%", state: .success),
            ]
        )
    }
}

private extension SubscriptionQuota {
    static var previewMenuBarCodexUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 20, resetsAt: "2026-07-03T02:24:00Z"),
                QuotaTier(name: "seven_day", utilization: 10, resetsAt: "2026-07-07T12:00:00Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }

    static var previewMenuBarCursorUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "cursor",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: CursorUsageLimitKind.autoComposer.rawValue, utilization: 5, resetsAt: "2026-07-30T03:12:17Z"),
                QuotaTier(name: CursorUsageLimitKind.api.rawValue, utilization: 40, resetsAt: "2026-07-30T03:12:17Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }

    static var previewMenuBarClaudeUsage: SubscriptionQuota {
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
