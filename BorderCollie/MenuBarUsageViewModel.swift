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
    let icon: AgentIcon
    /// One-line summary. Carries the failure text when `limits` is empty.
    let detail: String
    /// Per-window breakdown, rendered with a reset countdown. Empty unless the
    /// query succeeded.
    let limits: [UsageLimitDisplay]
    let state: MenuBarUsageRowState

    init(
        id: String,
        title: String,
        icon: AgentIcon,
        detail: String,
        limits: [UsageLimitDisplay] = [],
        state: MenuBarUsageRowState
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.detail = detail
        self.limits = limits
        self.state = state
    }
}

struct MenuBarUsageAgent: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: AgentIcon
    let service: any UsageTrackingService
    let compactSummary: @Sendable (SubscriptionQuota) -> String
    let usageLimits: @Sendable (SubscriptionQuota) -> [UsageLimitDisplay]

    static func codex(service: any UsageTrackingService = CodexQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "codex",
            title: "Codex",
            icon: .codex,
            service: service,
            compactSummary: CodexUsageLimitDisplay.compactSummary,
            usageLimits: CodexUsageLimitDisplay.usageLimits
        )
    }

    static func cursor(service: any UsageTrackingService = CursorQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "cursor",
            title: "Cursor",
            icon: .cursor,
            service: service,
            compactSummary: CursorUsageLimitDisplay.compactSummary,
            usageLimits: CursorUsageLimitDisplay.usageLimits
        )
    }

    static func claudeCode(service: any UsageTrackingService = ClaudeQuotaService.live) -> MenuBarUsageAgent {
        MenuBarUsageAgent(
            id: "claude_code",
            title: "Claude Code",
            icon: .claudeCode,
            service: service,
            compactSummary: ClaudeUsageLimitDisplay.compactSummary,
            usageLimits: ClaudeUsageLimitDisplay.usageLimits
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
                icon: agent.icon,
                detail: agent.compactSummary(quota),
                limits: agent.usageLimits(quota),
                state: .success
            )
        case .success(let quota):
            MenuBarUsageRow(
                id: agent.id,
                title: agent.title,
                icon: agent.icon,
                detail: unavailableText(for: quota),
                state: .unavailable
            )
        case .failure(.timedOut):
            MenuBarUsageRow(
                id: agent.id,
                title: agent.title,
                icon: agent.icon,
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
            icon: agent.icon,
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
                previewRow(id: "codex", title: "Codex", icon: .codex, quota: .previewMenuBarCodexUsage, limits: CodexUsageLimitDisplay.usageLimits),
                previewRow(id: "cursor", title: "Cursor", icon: .cursor, quota: .previewMenuBarCursorUsage, limits: CursorUsageLimitDisplay.usageLimits),
                previewRow(id: "claude_code", title: "Claude Code", icon: .claudeCode, quota: .previewMenuBarClaudeUsage, limits: ClaudeUsageLimitDisplay.usageLimits),
            ]
        )
    }

    private static func previewRow(
        id: String,
        title: String,
        icon: AgentIcon,
        quota: SubscriptionQuota,
        limits: (SubscriptionQuota) -> [UsageLimitDisplay]
    ) -> MenuBarUsageRow {
        let resolved = limits(quota)
        return MenuBarUsageRow(
            id: id,
            title: title,
            icon: icon,
            detail: resolved.map { "\($0.title): \($0.percentageText)" }.joined(separator: " | "),
            limits: resolved,
            state: .success
        )
    }
}

private func previewResetsAt(inHours hours: Double) -> String {
    ISO8601DateFormatter.codexWithoutFractionalSeconds.string(from: Date().addingTimeInterval(hours * 3_600))
}

private extension SubscriptionQuota {
    static var previewMenuBarCodexUsage: SubscriptionQuota {
        SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 20, resetsAt: previewResetsAt(inHours: 3.4)),
                QuotaTier(name: "seven_day", utilization: 10, resetsAt: previewResetsAt(inHours: 86)),
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
                QuotaTier(name: CursorUsageLimitKind.autoComposer.rawValue, utilization: 5, resetsAt: previewResetsAt(inHours: 320)),
                QuotaTier(name: CursorUsageLimitKind.api.rawValue, utilization: 40, resetsAt: previewResetsAt(inHours: 320)),
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
                QuotaTier(name: ClaudeUsageLimitKind.fiveHour.rawValue, utilization: 48, resetsAt: previewResetsAt(inHours: 4.5)),
                QuotaTier(name: ClaudeUsageLimitKind.week.rawValue, utilization: 64, resetsAt: previewResetsAt(inHours: 158)),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: Date().millisecondsSince1970
        )
    }
}
