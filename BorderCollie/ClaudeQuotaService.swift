import Foundation

struct ClaudeQuotaService: UsageTrackingService {
    private let credentialResolver: ClaudeCredentialResolving
    private let usageClient: ClaudeUsageClient
    private let now: @Sendable () -> Date

    let toolID = "claude_code"

    static let live = ClaudeQuotaService(
        credentialResolver: ClaudeCredentialResolver(),
        usageClient: ClaudeUsageClient()
    )

    init(
        credentialResolver: ClaudeCredentialResolving,
        usageClient: ClaudeUsageClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialResolver = credentialResolver
        self.usageClient = usageClient
        self.now = now
    }

    func getSubscriptionQuota() async -> SubscriptionQuota {
        await usageClient.singleFlight { [self] in
            await resolveAndQuery()
        }
    }

    private func resolveAndQuery() async -> SubscriptionQuota {
        // Most polls land inside the gate's minimum interval or a 429 cooldown
        // and will be answered from cache, so don't touch the keychain for them.
        if let throttled = await usageClient.throttledQuota() {
            return throttled
        }

        let credentials = credentialResolver.readClaudeCredentials()

        switch credentials.status {
        case .notFound:
            return .notFound(tool: toolID)

        case .parseError:
            return .error(
                tool: toolID,
                status: .parseError,
                message: credentials.message ?? "Failed to parse Claude Code credentials",
                now: now()
            )

        case .expired:
            // Expiry without a usable refresh token. The token may still work if
            // the local clock is ahead, so try once before reporting sign-in.
            if credentials.accessToken != nil {
                let result = await usageClient.queryClaudeQuota(credentials: credentials)
                if result.success {
                    return result
                }
            }

            return .error(
                tool: toolID,
                status: .expired,
                message: credentials.message ?? "Claude Code credentials need refresh",
                now: now()
            )

        case .valid:
            guard credentials.accessToken != nil else {
                return .error(
                    tool: toolID,
                    status: .parseError,
                    message: "Claude Code access token is empty or missing",
                    now: now()
                )
            }

            return await usageClient.queryClaudeQuota(credentials: credentials)
        }
    }
}
