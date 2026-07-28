import Foundation

struct ClaudeUsageClient: Sendable {
    private let httpClient: UsageHTTPClient
    private let endpoint: URL
    private let requestGate: ClaudeUsageRequestGate
    private let now: @Sendable () -> Date

    init(
        httpClient: UsageHTTPClient = URLSessionUsageHTTPClient(),
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        requestGate: ClaudeUsageRequestGate = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.endpoint = endpoint
        self.requestGate = requestGate
        self.now = now
    }

    func queryClaudeQuota(
        accessToken: String,
        toolLabel: String = "claude_code",
        expiredMessage: String = "Authentication failed. Please sign in with Claude Code again."
    ) async -> SubscriptionQuota {
        let currentTime = now()
        switch await requestGate.decision(now: currentTime) {
        case .serveCached(let cached):
            return cached
        case .allowNetwork:
            break
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.220", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            await requestGate.recordFailure(at: now())
            return SubscriptionQuota.error(
                tool: toolLabel,
                status: .valid,
                message: "Network error: \(error.localizedDescription)",
                now: now()
            )
        }

        switch response.statusCode {
        case 200..<300:
            let quota = decodeUsageResponse(data, toolLabel: toolLabel)
            if quota.success {
                await requestGate.recordSuccess(quota, at: now())
            } else {
                await requestGate.recordFailure(at: now())
            }
            return quota
        case 401, 403:
            await requestGate.recordFailure(at: now())
            return SubscriptionQuota.error(
                tool: toolLabel,
                status: .expired,
                message: "\(expiredMessage) (HTTP \(response.statusCode))",
                now: now()
            )
        case 429:
            return await requestGate.recordRateLimit(
                retryAfterSeconds: ClaudeUsageRequestGate.retryAfterSeconds(from: response),
                at: now()
            )
        default:
            await requestGate.recordFailure(at: now())
            return SubscriptionQuota.error(
                tool: toolLabel,
                status: .valid,
                message: "API error (HTTP \(response.statusCode)): \(bodyPreview(from: data))",
                now: now()
            )
        }
    }

    private func decodeUsageResponse(_ data: Data, toolLabel: String) -> SubscriptionQuota {
        let usageResponse: ClaudeOAuthUsageResponse
        do {
            usageResponse = try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
        } catch {
            return SubscriptionQuota.error(
                tool: toolLabel,
                status: .valid,
                message: "Failed to parse API response: \(error.localizedDescription)",
                now: now()
            )
        }

        let tiers = [
            usageResponse.fiveHour.map {
                QuotaTier(
                    name: ClaudeUsageLimitKind.fiveHour.rawValue,
                    utilization: $0.utilization,
                    resetsAt: Self.normalizedResetsAt($0.resetsAt)
                )
            },
            usageResponse.sevenDay.map {
                QuotaTier(
                    name: ClaudeUsageLimitKind.week.rawValue,
                    utilization: $0.utilization,
                    resetsAt: Self.normalizedResetsAt($0.resetsAt)
                )
            },
        ].compactMap { $0 }

        guard !tiers.isEmpty else {
            return SubscriptionQuota.error(
                tool: toolLabel,
                status: .valid,
                message: "Claude Code usage response did not include quota windows.",
                now: now()
            )
        }

        return SubscriptionQuota(
            tool: toolLabel,
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: tiers,
            extraUsage: nil,
            error: nil,
            queriedAt: now().millisecondsSince1970
        )
    }

    static func normalizedResetsAt(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        guard let date = parseResetDate(value) else {
            return value
        }

        return ISO8601DateFormatter.codexWithoutFractionalSeconds.string(from: date)
    }

    private static func parseResetDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter.codex.dateAllowingCodexFormats(from: value) {
            return date
        }

        var normalized = value
        if normalized.hasSuffix("+00:00") {
            normalized = String(normalized.dropLast(6)) + "Z"
        } else if let plusOffsetRange = normalized.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) {
            normalized = String(normalized[..<plusOffsetRange.lowerBound]) + "Z"
        }

        if let dotIndex = normalized.firstIndex(of: "."),
           let zIndex = normalized.firstIndex(of: "Z"),
           dotIndex < zIndex {
            let fractional = normalized[normalized.index(after: dotIndex)..<zIndex]
            let milliseconds = fractional.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized = String(normalized[..<normalized.index(after: dotIndex)]) + milliseconds + "Z"
        }

        return ISO8601DateFormatter.codex.dateAllowingCodexFormats(from: normalized)
    }

    private func bodyPreview(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.count > 300 else {
            return body
        }
        return "\(body.prefix(300))..."
    }
}

private struct ClaudeOAuthUsageResponse: Decodable {
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeOAuthUsageWindow: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
