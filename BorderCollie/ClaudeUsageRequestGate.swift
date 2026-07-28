import Foundation

/// Process-wide throttle for Claude Code's undocumented OAuth usage endpoint.
///
/// Anthropic's `/api/oauth/usage` rate-limits aggressive polling. BorderCollie
/// allows one Claude network fetch about every 60 seconds and backs off for at
/// least five minutes after HTTP 429. `Retry-After` is often `0` or missing, so
/// treat it as advisory only when it is greater than zero.
actor ClaudeUsageRequestGate {
    static let shared = ClaudeUsageRequestGate()

    static let minimumRefreshInterval: TimeInterval = 60
    static let defaultCooldownInterval: TimeInterval = 300

    private var lastSuccessfulQuota: SubscriptionQuota?
    private var lastNetworkFetchAt: Date?
    private var rateLimitedUntil: Date?

    enum Decision: Equatable {
        case serveCached(SubscriptionQuota)
        case allowNetwork
    }

    func decision(now: Date) -> Decision {
        if let rateLimitedUntil, now < rateLimitedUntil, let cached = lastSuccessfulQuota {
            return .serveCached(cached)
        }

        if let rateLimitedUntil, now < rateLimitedUntil {
            return .serveCached(
                .error(
                    tool: "claude_code",
                    status: .valid,
                    message: Self.rateLimitedMessage(retryAt: rateLimitedUntil, now: now),
                    now: now
                )
            )
        }

        if let lastNetworkFetchAt,
           now.timeIntervalSince(lastNetworkFetchAt) < Self.minimumRefreshInterval,
           let cached = lastSuccessfulQuota {
            return .serveCached(cached)
        }

        return .allowNetwork
    }

    func recordSuccess(_ quota: SubscriptionQuota, at now: Date) {
        lastSuccessfulQuota = quota
        lastNetworkFetchAt = now
        rateLimitedUntil = nil
    }

    func recordRateLimit(retryAfterSeconds: TimeInterval?, at now: Date) -> SubscriptionQuota {
        let cooldown = max(retryAfterSeconds ?? 0, Self.defaultCooldownInterval)
        let retryAt = now.addingTimeInterval(cooldown)
        rateLimitedUntil = retryAt
        lastNetworkFetchAt = now

        if let cached = lastSuccessfulQuota {
            return cached
        }

        return .error(
            tool: "claude_code",
            status: .valid,
            message: Self.rateLimitedMessage(retryAt: retryAt, now: now),
            now: now
        )
    }

    func recordFailure(at now: Date) {
        lastNetworkFetchAt = now
    }

    func reset() {
        lastSuccessfulQuota = nil
        lastNetworkFetchAt = nil
        rateLimitedUntil = nil
    }

    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }

        return nil
    }

    private static func rateLimitedMessage(retryAt: Date, now: Date) -> String {
        let seconds = max(Int(retryAt.timeIntervalSince(now).rounded(.up)), 1)
        let minutes = max((seconds + 59) / 60, 1)
        if minutes == 1 {
            return "Claude usage API rate limited. Try again in about 1 minute."
        }
        return "Claude usage API rate limited. Try again in about \(minutes) minutes."
    }
}
