import Foundation

struct ClaudeUsageClient: Sendable {
    private let httpClient: UsageHTTPClient
    private let endpoint: URL
    private let requestGate: ClaudeUsageRequestGate
    private let tokenRefresher: any ClaudeTokenRefreshing
    private let now: @Sendable () -> Date

    init(
        httpClient: UsageHTTPClient = URLSessionUsageHTTPClient(),
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        requestGate: ClaudeUsageRequestGate = .shared,
        tokenRefresher: any ClaudeTokenRefreshing = ClaudeTokenRefresher.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.endpoint = endpoint
        self.requestGate = requestGate
        self.tokenRefresher = tokenRefresher
        self.now = now
    }

    /// Queries usage with automatic OAuth refresh.
    ///
    /// The stored access token is short-lived and only the CLI renews it, so a
    /// background poller has to refresh both proactively (token at or past its
    /// expiry) and reactively (server says 401 anyway — clock skew, or the token
    /// was revoked server-side before its nominal expiry).
    func queryClaudeQuota(
        credentials: ClaudeCredentials,
        toolLabel: String = "claude_code",
        expiredMessage: String = "Authentication failed. Please sign in with Claude Code again."
    ) async -> SubscriptionQuota {
        switch await requestGate.decision(now: now()) {
        case .serveCached(let cached):
            return cached
        case .allowNetwork:
            break
        }

        guard var accessToken = credentials.accessToken else {
            await requestGate.recordFailure(at: now())
            return .error(
                tool: toolLabel,
                status: .parseError,
                message: "Claude Code access token is empty or missing",
                now: now()
            )
        }

        var refreshFailure: ClaudeTokenRefreshError?

        if credentials.needsRefresh(now: now()), credentials.canRefresh {
            switch await tokenRefresher.refresh(credentials) {
            case .success(let refreshed):
                accessToken = refreshed.accessToken
            case .failure(let error):
                refreshFailure = error
            }
        }

        var outcome = await fetchUsage(accessToken: accessToken, toolLabel: toolLabel)

        if case .unauthorized = outcome, credentials.canRefresh {
            switch await tokenRefresher.refresh(credentials) {
            case .success(let refreshed):
                accessToken = refreshed.accessToken
                outcome = await fetchUsage(accessToken: accessToken, toolLabel: toolLabel)
            case .failure(let error):
                refreshFailure = error
            }
        }

        return await finish(
            outcome,
            toolLabel: toolLabel,
            expiredMessage: expiredMessage,
            refreshFailure: refreshFailure
        )
    }

    /// Queries usage with a caller-supplied token and no refresh capability.
    func queryClaudeQuota(
        accessToken: String,
        toolLabel: String = "claude_code",
        expiredMessage: String = "Authentication failed. Please sign in with Claude Code again."
    ) async -> SubscriptionQuota {
        switch await requestGate.decision(now: now()) {
        case .serveCached(let cached):
            return cached
        case .allowNetwork:
            break
        }

        let outcome = await fetchUsage(accessToken: accessToken, toolLabel: toolLabel)
        return await finish(
            outcome,
            toolLabel: toolLabel,
            expiredMessage: expiredMessage,
            refreshFailure: nil
        )
    }

    private enum FetchOutcome {
        case quota(SubscriptionQuota)
        case unauthorized(statusCode: Int, missingScope: Bool)
        case rateLimited(retryAfter: TimeInterval?)
        case transportError(String)
        case httpError(statusCode: Int, bodyPreview: String)
    }

    private func fetchUsage(accessToken: String, toolLabel: String) async -> FetchOutcome {
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
            return .transportError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200..<300:
            return .quota(decodeUsageResponse(data, toolLabel: toolLabel))
        case 401, 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            return .unauthorized(
                statusCode: response.statusCode,
                missingScope: response.statusCode == 403 && body.contains("user:profile")
            )
        case 429:
            return .rateLimited(retryAfter: ClaudeUsageRequestGate.retryAfterSeconds(from: response))
        default:
            return .httpError(statusCode: response.statusCode, bodyPreview: bodyPreview(from: data))
        }
    }

    private func finish(
        _ outcome: FetchOutcome,
        toolLabel: String,
        expiredMessage: String,
        refreshFailure: ClaudeTokenRefreshError?
    ) async -> SubscriptionQuota {
        switch outcome {
        case .quota(let quota):
            if quota.success {
                await requestGate.recordSuccess(quota, at: now())
            } else {
                await requestGate.recordFailure(at: now())
            }
            return quota

        case .unauthorized(let statusCode, let missingScope):
            await requestGate.recordFailure(at: now())
            if missingScope {
                return .error(
                    tool: toolLabel,
                    status: .expired,
                    message: "Claude OAuth token is missing the 'user:profile' scope. Run 'claude setup-token'.",
                    now: now()
                )
            }
            return .error(
                tool: toolLabel,
                status: .expired,
                message: "\(expiredMessage)\(Self.refreshSuffix(refreshFailure)) (HTTP \(statusCode))",
                now: now()
            )

        case .rateLimited(let retryAfter):
            return await requestGate.recordRateLimit(retryAfterSeconds: retryAfter, at: now())

        case .transportError(let description):
            await requestGate.recordFailure(at: now())
            return .error(
                tool: toolLabel,
                status: .valid,
                message: "Network error: \(description)",
                now: now()
            )

        case .httpError(let statusCode, let preview):
            await requestGate.recordFailure(at: now())
            return .error(
                tool: toolLabel,
                status: .valid,
                message: "API error (HTTP \(statusCode)): \(preview)",
                now: now()
            )
        }
    }

    private static func refreshSuffix(_ failure: ClaudeTokenRefreshError?) -> String {
        switch failure {
        case nil:
            ""
        case .notRefreshable:
            " Token refresh unavailable — no stored refresh token."
        case .notWritable:
            " BorderCollie cannot write to Claude Code's credential store, so it "
                + "will not refresh the token; grant keychain access or run 'claude'."
        case .rejected(let statusCode):
            " Token refresh was rejected (HTTP \(statusCode))."
        case .malformedResponse:
            " Token refresh returned an unreadable response."
        case .transport(let description):
            " Token refresh failed: \(description)."
        }
    }

    private func decodeUsageResponse(_ data: Data, toolLabel: String) -> SubscriptionQuota {
        let usageResponse: ClaudeOAuthUsageResponse
        do {
            usageResponse = try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
        } catch {
            return .error(
                tool: toolLabel,
                status: .valid,
                message: "Failed to parse API response: \(error.localizedDescription)",
                now: now()
            )
        }

        var tiers: [QuotaTier] = []

        if let fiveHour = usageResponse.fiveHour {
            tiers.append(
                QuotaTier(
                    name: ClaudeUsageLimitKind.fiveHour.rawValue,
                    utilization: fiveHour.utilization,
                    resetsAt: Self.normalizedResetsAt(fiveHour.resetsAt)
                )
            )
        }

        if let sevenDay = usageResponse.sevenDay {
            tiers.append(
                QuotaTier(
                    name: ClaudeUsageLimitKind.week.rawValue,
                    utilization: sevenDay.utilization,
                    resetsAt: Self.normalizedResetsAt(sevenDay.resetsAt)
                )
            )
        }

        // Model-scoped weekly windows arrive two ways. The structured `limits`
        // array is authoritative, so let it overwrite any flat `seven_day_<model>`
        // key for the same model.
        var modelTiers: [String: QuotaTier] = [:]
        for (model, window) in usageResponse.modelWindows {
            modelTiers[model] = QuotaTier(
                name: ClaudeUsageLimitKind.modelWeekTierName(model: model),
                utilization: window.utilization,
                resetsAt: Self.normalizedResetsAt(window.resetsAt)
            )
        }
        for limit in usageResponse.limits {
            guard limit.kind == "weekly_scoped", limit.isActive != false,
                  let percent = limit.percent,
                  let model = (limit.scope?.model?.displayName ?? limit.scope?.model?.id)?
                      .lowercased()
                      .replacingOccurrences(of: " ", with: "_"),
                  !model.isEmpty
            else {
                continue
            }

            modelTiers[model] = QuotaTier(
                name: ClaudeUsageLimitKind.modelWeekTierName(model: model),
                utilization: percent,
                resetsAt: Self.normalizedResetsAt(limit.resetsAt)
            )
        }
        tiers.append(contentsOf: modelTiers.keys.sorted().compactMap { modelTiers[$0] })

        guard !tiers.isEmpty else {
            return .error(
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
            extraUsage: usageResponse.extraUsage?.formatted,
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
    /// `seven_day_<model>` keys, keyed by model name.
    let modelWindows: [String: ClaudeOAuthUsageWindow]
    let limits: [ClaudeOAuthLimit]
    let extraUsage: ClaudeOAuthExtraUsage?

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let modelWindowPrefix = "seven_day_"

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        func window(_ key: String) -> ClaudeOAuthUsageWindow? {
            guard let codingKey = DynamicKey(stringValue: key) else { return nil }
            return try? container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: codingKey)
        }

        fiveHour = window("five_hour")
        sevenDay = window("seven_day")

        var windows: [String: ClaudeOAuthUsageWindow] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix(Self.modelWindowPrefix) {
            guard let value = try? container.decodeIfPresent(ClaudeOAuthUsageWindow.self, forKey: key) else {
                continue
            }
            windows[String(key.stringValue.dropFirst(Self.modelWindowPrefix.count))] = value
        }
        modelWindows = windows

        limits = DynamicKey(stringValue: "limits")
            .flatMap { try? container.decodeIfPresent([ClaudeOAuthLimit].self, forKey: $0) } ?? []
        extraUsage = DynamicKey(stringValue: "extra_usage")
            .flatMap { try? container.decodeIfPresent(ClaudeOAuthExtraUsage.self, forKey: $0) }
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

private struct ClaudeOAuthLimit: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable {
            let id: String?
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        let model: Model?
    }

    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: Scope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }
}

private struct ClaudeOAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    /// Cents.
    let monthlyLimit: Double?
    /// Cents.
    let usedCredits: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case currency
    }

    var formatted: String? {
        guard isEnabled == true, let monthlyLimit, let usedCredits else {
            return nil
        }

        var format = FloatingPointFormatStyle<Double>.Currency(code: currency?.uppercased() ?? "USD")
        format = format.precision(.fractionLength(2))
        return "\((usedCredits / 100).formatted(format)) of \((monthlyLimit / 100).formatted(format))"
    }
}
