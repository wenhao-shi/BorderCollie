import Foundation
import Testing
@testable import BorderCollie

struct BorderCollieTests {
    @Test func mapsKnownAndUnknownQuotaWindows() {
        #expect(CodexUsageFormatting.windowSecondsToTierName(18_000) == "five_hour")
        #expect(CodexUsageFormatting.windowSecondsToTierName(604_800) == "seven_day")
        #expect(CodexUsageFormatting.windowSecondsToTierName(3_600) == "1_hour")
        #expect(CodexUsageFormatting.windowSecondsToTierName(172_800) == "2_day")
    }

    @Test func convertsUnixTimestampToISO8601() {
        #expect(CodexUsageFormatting.unixTimestampToISO8601(1_780_000_000) == "2026-05-28T20:26:40Z")
        #expect(CodexUsageFormatting.unixTimestampToISO8601(-1) == nil)
    }

    @Test func countdownParsesNormalizedResetTimestamp() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-05-28T18:56:40Z")!

        #expect(
            CodexUsageFormatting.countdownString(
                until: "2026-05-28T20:26:40Z",
                now: now
            ) == "1h30m"
        )
    }

    @Test func codexUsageLimitDisplayShowsUsedUsageAndResetText() {
        let quota = SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "seven_day", utilization: 40, resetsAt: "2026-07-07T12:00:00Z"),
                QuotaTier(name: "five_hour", utilization: 80, resetsAt: "2026-07-02T19:24:00Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        let limits = CodexUsageLimitDisplay.expectedLimits(from: quota)
        // Pinned rather than defaulted to the current date: reset precision now
        // depends on the distance to `now`, so a floating clock would make the
        // expectations drift.
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-02T12:00:00Z")!
        let utc = TimeZone(secondsFromGMT: 0)!

        #expect(limits.map(\.title) == ["5h", "7d"])
        #expect(limits.map(\.percentageText) == ["80%", "40%"])
        // ICU uses a narrow no-break space (U+202F) before AM/PM.
        #expect(
            limits.map {
                $0.resetText(now: now, timeZone: utc)?
                    .replacingOccurrences(of: "\u{202F}", with: " ")
            } == ["7:24 PM", "Tue 12:00 PM"]
        )
    }

    @Test func cursorUsageLimitDisplayShowsMonthlyBuckets() {
        let quota = SubscriptionQuota(
            tool: "cursor",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "cursor_api", utilization: 0, resetsAt: "2026-07-30T03:12:17Z"),
                QuotaTier(name: "cursor_auto_composer", utilization: 1.25, resetsAt: "2026-07-30T03:12:17Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        let limits = CursorUsageLimitDisplay.usageLimits(from: quota)

        #expect(limits.map(\.title) == ["Auto + Composer", "API"])
        #expect(limits.map(\.percentageText) == ["1.2%", "0%"])
        #expect(limits.map { $0.resetText(timeZone: TimeZone(secondsFromGMT: 0)!) } == ["Jul 30", "Jul 30"])
    }

    @Test func codexCompactSummaryShowsUsedUsage() {
        let quota = SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 20, resetsAt: nil),
                QuotaTier(name: "seven_day", utilization: 10, resetsAt: nil),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        #expect(CodexUsageLimitDisplay.compactSummary(from: quota) == "5h: 20% | 7d: 10%")
    }

    @Test func cursorCompactSummaryShowsUsedUsage() {
        let quota = SubscriptionQuota(
            tool: "cursor",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "cursor_api", utilization: 40, resetsAt: nil),
                QuotaTier(name: "cursor_auto_composer", utilization: 5, resetsAt: nil),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        #expect(CursorUsageLimitDisplay.compactSummary(from: quota) == "Auto: 5% | API: 40%")
    }

    @Test func compactSummaryHandlesMissingClampedAndRoundedTiers() {
        let codexQuota = SubscriptionQuota(
            tool: "codex",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 20.4, resetsAt: nil),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )
        let cursorQuota = SubscriptionQuota(
            tool: "cursor",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "cursor_auto_composer", utilization: -2, resetsAt: nil),
                QuotaTier(name: "cursor_api", utilization: 125, resetsAt: nil),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        #expect(CodexUsageLimitDisplay.compactSummary(from: codexQuota) == "5h: 20% | 7d: --")
        #expect(CursorUsageLimitDisplay.compactSummary(from: cursorQuota) == "Auto: 0% | API: 100%")
        #expect(ClaudeUsageLimitDisplay.compactSummary(from: codexQuota) == "5h: 20% | 7d: --")
    }

    @Test func credentialParserRejectsNonChatGPTOAuthMode() {
        let credentials = CodexCredentialResolver.parseCodexCredentialsJSON(
            """
            {
              "auth_mode": "api_key",
              "tokens": {
                "access_token": "token"
              }
            }
            """
        )

        #expect(credentials.status == .notFound)
        #expect(credentials.accessToken == nil)
    }

    @Test func credentialParserReportsMissingTokenAsParseError() {
        let credentials = CodexCredentialResolver.parseCodexCredentialsJSON(
            """
            {
              "auth_mode": "chatgpt",
              "tokens": {}
            }
            """
        )

        #expect(credentials.status == .parseError)
        #expect(credentials.message == "access_token is empty or missing")
    }

    @Test func credentialParserPreservesStaleTokenForOptimisticRemoteAttempt() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-02T12:00:00Z")!
        let credentials = CodexCredentialResolver.parseCodexCredentialsJSON(
            """
            {
              "auth_mode": "chatgpt",
              "tokens": {
                "access_token": "token",
                "account_id": "acct_123"
              },
              "last_refresh": "2026-06-20T12:00:00Z"
            }
            """,
            now: now
        )

        #expect(credentials.status == .expired)
        #expect(credentials.accessToken == "token")
        #expect(credentials.accountID == "acct_123")
    }

    @Test func quotaClientNormalizesSuccessfulUsageResponse() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-02T12:00:00Z")!
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 42.5,
                  "limit_window_seconds": 18000,
                  "reset_at": 1780000000
                },
                "secondary_window": {
                  "used_percent": 12.0,
                  "limit_window_seconds": 604800,
                  "reset_at": 1780500000
                }
              }
            }
            """
        )
        let client = CodexUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/usage")!,
            now: { now }
        )

        let quota = await client.queryCodexQuota(
            accessToken: "secret-token",
            accountID: "acct_123"
        )

        #expect(quota.success)
        #expect(quota.credentialStatus == .valid)
        #expect(quota.queriedAt == 1_782_993_600_000)
        #expect(quota.tiers == [
            QuotaTier(name: "five_hour", utilization: 42.5, resetsAt: "2026-05-28T20:26:40Z"),
            QuotaTier(name: "seven_day", utilization: 12.0, resetsAt: "2026-06-03T15:20:00Z"),
        ])

        let request = await httpClient.lastRequest()
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct_123")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.timeoutInterval == 15)
    }

    @Test func quotaClientMapsUnauthorizedResponseToExpiredCredentials() async {
        let httpClient = CapturingHTTPClient(statusCode: 401, body: "{}")
        let client = CodexUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/usage")!,
            now: { Date(timeIntervalSince1970: 1_783_080_000) }
        )

        let quota = await client.queryCodexQuota(
            accessToken: "secret-token",
            accountID: nil
        )

        #expect(!quota.success)
        #expect(quota.credentialStatus == .expired)
        #expect(quota.error == "Authentication failed. Please re-login with Codex CLI. (HTTP 401)")
        #expect(quota.queriedAt == 1_783_080_000_000)
    }

    @Test func cursorCredentialResolverReadsTokenFromStateDatabase() {
        let resolver = CursorCredentialResolver(
            stateDatabaseURL: URL(fileURLWithPath: "/tmp/state.vscdb"),
            fileExists: { _ in true },
            databaseReader: { _ in "cursor-token\n" }
        )

        let credentials = resolver.readCursorCredentials()

        #expect(credentials.status == .valid)
        #expect(credentials.accessToken == "cursor-token")
    }

    @Test func cursorUsageClientNormalizesCurrentPeriodUsageResponse() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-03T12:00:00Z")!
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "billingCycleStart": "1782807137000",
              "billingCycleEnd": "1785399137000",
              "planUsage": {
                "totalSpend": 55,
                "includedSpend": 55,
                "remaining": 6945,
                "limit": 7000,
                "autoPercentUsed": 0.1375,
                "apiPercentUsed": 0,
                "totalPercentUsed": 0.10784313725490195
              },
              "enabled": true,
              "displayMessage": "You've used 1% of your included usage"
            }
            """
        )
        let client = CursorUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/cursor")!,
            now: { now }
        )

        let quota = await client.queryCursorQuota(accessToken: "cursor-secret")

        #expect(quota.success)
        #expect(quota.credentialStatus == .valid)
        #expect(quota.queriedAt == 1_783_080_000_000)
        #expect(quota.extraUsage == "You've used 1% of your included usage")
        #expect(quota.tiers == [
            QuotaTier(name: "cursor_auto_composer", utilization: 0.1375, resetsAt: "2026-07-30T08:12:17Z"),
            QuotaTier(name: "cursor_api", utilization: 0, resetsAt: "2026-07-30T08:12:17Z"),
        ])

        let request = await httpClient.lastRequest()
        #expect(request?.httpMethod == "POST")
        #expect(request?.httpBody == Data("{}".utf8))
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-secret")
        #expect(request?.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request?.timeoutInterval == 15)
    }

    @Test func cursorUsageClientMapsUnauthorizedResponseToExpiredCredentials() async {
        let httpClient = CapturingHTTPClient(statusCode: 403, body: "{}")
        let client = CursorUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/cursor")!,
            now: { Date(timeIntervalSince1970: 1_783_080_000) }
        )

        let quota = await client.queryCursorQuota(accessToken: "cursor-secret")

        #expect(!quota.success)
        #expect(quota.credentialStatus == .expired)
        #expect(quota.error == "Authentication failed. Please sign in to Cursor again. (HTTP 403)")
        #expect(quota.queriedAt == 1_783_080_000_000)
    }

    @Test func cursorQuotaServiceMapsMissingCredentials() async {
        let service = CursorQuotaService(
            credentialResolver: StubCursorCredentialResolver(
                credentials: CursorCredentials(accessToken: nil, status: .notFound, message: nil)
            ),
            usageClient: CursorUsageClient(
                httpClient: CapturingHTTPClient(statusCode: 200, body: "{}"),
                endpoint: URL(string: "https://example.test/cursor")!
            )
        )

        let quota = await service.getSubscriptionQuota()

        #expect(quota == .notFound(tool: "cursor"))
    }


    @Test func claudeCompactSummaryShowsUsedUsage() {
        let quota = SubscriptionQuota(
            tool: "claude_code",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 48, resetsAt: nil),
                QuotaTier(name: "seven_day", utilization: 64, resetsAt: nil),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )

        #expect(ClaudeUsageLimitDisplay.compactSummary(from: quota) == "5h: 48% | 7d: 64%")
    }

    @Test func claudeCredentialParserReadsValidOAuthToken() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            """
            {
              "claudeAiOauth": {
                "accessToken": "sk-ant-oat01-test",
                "expiresAt": 1785200000000
              }
            }
            """,
            now: now
        )

        #expect(credentials.status == .valid)
        #expect(credentials.accessToken == "sk-ant-oat01-test")
    }

    @Test func claudeCredentialParserPreservesExpiredTokenForOptimisticRemoteAttempt() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T16:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            """
            {
              "claudeAiOauth": {
                "accessToken": "sk-ant-oat01-expired",
                "expiresAt": 1785166162351
              }
            }
            """,
            now: now
        )

        #expect(credentials.status == .expired)
        #expect(credentials.accessToken == "sk-ant-oat01-expired")
        #expect(credentials.message == "Claude Code OAuth token has expired")
    }

    @Test func claudeCredentialParserReportsMissingOAuthAsNotFound() {
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            """
            {
              "other": true
            }
            """
        )

        #expect(credentials.status == .notFound)
        #expect(credentials.accessToken == nil)
    }

    @Test func claudeUsageClientNormalizesOAuthUsageResponse() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "five_hour": {
                "utilization": 48.0,
                "resets_at": "2026-07-27T17:00:00.521744+00:00"
              },
              "seven_day": {
                "utilization": 64.0,
                "resets_at": "2026-08-01T06:00:00.521764+00:00"
              },
              "seven_day_opus": null,
              "extra_usage": {
                "is_enabled": false,
                "monthly_limit": null,
                "used_credits": 0,
                "utilization": null
              }
            }
            """
        )
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            now: { now }
        )

        let quota = await client.queryClaudeQuota(accessToken: "claude-secret")

        #expect(quota.success)
        #expect(quota.credentialStatus == .valid)
        #expect(quota.queriedAt == 1_785_153_600_000)
        #expect(quota.tiers == [
            QuotaTier(name: "five_hour", utilization: 48.0, resetsAt: "2026-07-27T17:00:00Z"),
            QuotaTier(name: "seven_day", utilization: 64.0, resetsAt: "2026-08-01T06:00:00Z"),
        ])

        let request = await httpClient.lastRequest()
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer claude-secret")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.timeoutInterval == 15)
    }

    @Test func claudeUsageClientMapsUnauthorizedResponseToExpiredCredentials() async {
        let httpClient = CapturingHTTPClient(statusCode: 401, body: "{}")
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate()
        )

        let quota = await client.queryClaudeQuota(accessToken: "claude-secret")

        #expect(!quota.success)
        #expect(quota.credentialStatus == .expired)
        #expect(quota.error == "Authentication failed. Please sign in with Claude Code again. (HTTP 401)")
    }

    @Test func claudeUsageClientServesCachedQuotaInsideMinimumRefreshInterval() async {
        let start = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let clock = ClaudeTestClock(start)
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "five_hour": { "utilization": 10.0, "resets_at": "2026-07-27T17:00:00Z" },
              "seven_day": { "utilization": 20.0, "resets_at": "2026-08-01T06:00:00Z" }
            }
            """
        )
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            now: { clock.now() }
        )

        let first = await client.queryClaudeQuota(accessToken: "claude-secret")
        clock.advance(seconds: 30)
        let second = await client.queryClaudeQuota(accessToken: "claude-secret")

        #expect(first.success)
        #expect(second == first)
        #expect(await httpClient.requestCount() == 1)
    }

    @Test func claudeUsageClientBacksOffOnRateLimitAndPreservesLastSuccess() async {
        let start = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let clock = ClaudeTestClock(start)
        let successClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "five_hour": { "utilization": 10.0, "resets_at": "2026-07-27T17:00:00Z" },
              "seven_day": { "utilization": 20.0, "resets_at": "2026-08-01T06:00:00Z" }
            }
            """
        )
        let gate = ClaudeUsageRequestGate()
        let successQuery = ClaudeUsageClient(
            httpClient: successClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: gate,
            now: { clock.now() }
        )
        let first = await successQuery.queryClaudeQuota(accessToken: "claude-secret")

        clock.advance(seconds: ClaudeUsageRequestGate.minimumRefreshInterval)
        let limitedClient = CapturingHTTPClient(
            statusCode: 429,
            body: #"{"error":{"type":"rate_limit_error","message":"Rate limited"}}"#,
            headerFields: ["Retry-After": "0"]
        )
        let limitedQuery = ClaudeUsageClient(
            httpClient: limitedClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: gate,
            now: { clock.now() }
        )
        let second = await limitedQuery.queryClaudeQuota(accessToken: "claude-secret")
        let third = await limitedQuery.queryClaudeQuota(accessToken: "claude-secret")

        #expect(first.success)
        #expect(second == first)
        #expect(third == first)
        #expect(await limitedClient.requestCount() == 1)
    }

    @Test func claudeUsageRequestGateIgnoresZeroRetryAfterHeader() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test/oauth/usage")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "0"]
        )!

        #expect(ClaudeUsageRequestGate.retryAfterSeconds(from: response) == nil)
    }

    @Test func claudeQuotaServiceMapsMissingCredentials() async {
        let service = ClaudeQuotaService(
            credentialResolver: StubClaudeCredentialResolver(
                credentials: ClaudeCredentials(accessToken: nil, status: .notFound, message: nil)
            ),
            usageClient: ClaudeUsageClient(
                httpClient: CapturingHTTPClient(statusCode: 500, body: "{}"),
                requestGate: ClaudeUsageRequestGate()
            )
        )

        let quota = await service.getSubscriptionQuota()

        #expect(quota == .notFound(tool: "claude_code"))
    }

    @MainActor
    @Test func menuBarViewModelRefreshesAgentsConcurrentlyInFixedOrder() async {

        let probe = RefreshConcurrencyProbe()
        let codexService = StubUsageTrackingService(
            toolID: "codex",
            quota: SubscriptionQuota(
                tool: "codex",
                credentialStatus: .valid,
                credentialMessage: nil,
                success: true,
                tiers: [
                    QuotaTier(name: "five_hour", utilization: 20, resetsAt: nil),
                    QuotaTier(name: "seven_day", utilization: 10, resetsAt: nil),
                ],
                extraUsage: nil,
                error: nil,
                queriedAt: nil
            ),
            onQuery: {
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(50))
                await probe.leave()
            }
        )
        let cursorService = StubUsageTrackingService(
            toolID: "cursor",
            quota: .notFound(tool: "cursor"),
            onQuery: {
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(50))
                await probe.leave()
            }
        )
        let claudeService = StubUsageTrackingService(
            toolID: "claude_code",
            quota: SubscriptionQuota(
                tool: "claude_code",
                credentialStatus: .valid,
                credentialMessage: nil,
                success: true,
                tiers: [
                    QuotaTier(name: "five_hour", utilization: 48, resetsAt: nil),
                    QuotaTier(name: "seven_day", utilization: 64, resetsAt: nil),
                ],
                extraUsage: nil,
                error: nil,
                queriedAt: nil
            ),
            onQuery: {
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(50))
                await probe.leave()
            }
        )
        let viewModel = MenuBarUsageViewModel(
            agents: [
                .codex(service: codexService),
                .cursor(service: cursorService),
                .claudeCode(service: claudeService),
            ]
        )

        await viewModel.refresh()

        #expect(await probe.maxRunningCount() == 3)
        #expect(viewModel.rows.map(\.title) == ["Codex", "Cursor", "Claude Code"])
        #expect(viewModel.rows.map(\.detail) == ["5h: 20% | 7d: 10%", "Sign in required", "5h: 48% | 7d: 64%"])
        #expect(viewModel.rows.map(\.state) == [.success, .unavailable, .success])
    }

    @MainActor
    @Test func menuBarViewModelPreservesRowsAndSkipsOverlappingRefresh() async {
        let serviceState = CountingUsageServiceState(
            quota: SubscriptionQuota(
                tool: "codex",
                credentialStatus: .valid,
                credentialMessage: nil,
                success: true,
                tiers: [
                    QuotaTier(name: "five_hour", utilization: 25, resetsAt: nil),
                    QuotaTier(name: "seven_day", utilization: 15, resetsAt: nil),
                ],
                extraUsage: nil,
                error: nil,
                queriedAt: nil
            )
        )
        let viewModel = MenuBarUsageViewModel(
            agents: [
                .codex(service: CountingUsageTrackingService(toolID: "codex", state: serviceState)),
            ],
            initialRows: [
                MenuBarUsageRow(id: "codex", title: "Codex", icon: .codex, detail: "5h: 20% | 7d: 10%", state: .success),
            ]
        )

        let refreshTask = Task { @MainActor in
            await viewModel.refresh()
        }
        while !viewModel.isRefreshing {
            await Task.yield()
        }

        #expect(viewModel.rows.first?.detail == "5h: 20% | 7d: 10%")

        await viewModel.refresh()
        await refreshTask.value

        #expect(await serviceState.callCount() == 1)
        #expect(viewModel.rows.first?.detail == "5h: 25% | 7d: 15%")
    }

    @MainActor
    @Test func menuBarViewModelMapsUnsuccessfulQuotaStates() async {
        let viewModel = MenuBarUsageViewModel(
            agents: [
                .codex(service: StubUsageTrackingService(toolID: "missing", quota: .notFound(tool: "missing"))),
                .codex(
                    service: StubUsageTrackingService(
                        toolID: "expired",
                        quota: .error(tool: "expired", status: .expired, message: "expired")
                    )
                ),
                .codex(
                    service: StubUsageTrackingService(
                        toolID: "parse",
                        quota: .error(tool: "parse", status: .parseError, message: "parse")
                    )
                ),
                .codex(
                    service: StubUsageTrackingService(
                        toolID: "valid-failure",
                        quota: .error(tool: "valid-failure", status: .valid, message: "remote")
                    )
                ),
            ]
        )

        await viewModel.refresh()

        #expect(viewModel.rows.map(\.detail) == [
            "Sign in required",
            "Sign in again",
            "Credential issue",
            "Query failed",
        ])
    }
}

// MARK: - Claude OAuth refresh

extension BorderCollieTests {
    @Test func claudeCredentialParserDecodesHexEncodedKeychainPayload() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-hex","expiresAt":1785200000000}}"#
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!

        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(hex, now: now, origin: .keychain)

        #expect(credentials.status == .valid)
        #expect(credentials.accessToken == "sk-ant-oat01-hex")
    }

    @Test func claudeCredentialParserTreatsExpiredTokenWithRefreshTokenAsUsable() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T16:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            """
            {
              "claudeAiOauth": {
                "accessToken": "sk-ant-oat01-stale",
                "refreshToken": "sk-ant-ort01-refresh",
                "expiresAt": 1785166162351,
                "scopes": ["user:profile", "user:inference"],
                "subscriptionType": "max"
              }
            }
            """,
            now: now,
            origin: .keychain
        )

        // An expired access token backed by a refresh token is routine, not a
        // reason to tell the user their session died.
        #expect(credentials.status == .valid)
        #expect(credentials.canRefresh)
        #expect(credentials.needsRefresh(now: now))
        #expect(credentials.refreshToken == "sk-ant-ort01-refresh")
        #expect(credentials.subscriptionType == "max")
    }

    @Test func claudeCredentialParserKeepsExpiredStatusWithoutRefreshToken() {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T16:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-stale","expiresAt":1785166162351}}"#,
            now: now,
            origin: .keychain
        )

        #expect(credentials.status == .expired)
        #expect(!credentials.canRefresh)
    }

    @Test func claudeCredentialDocumentRewritePreservesUnknownKeysAndStaysMinified() {
        let expiresAt = Date(timeIntervalSince1970: 1_785_200_000)
        let updated = ClaudeCredentialResolver.documentApplying(
            accessToken: "sk-ant-oat01-new",
            refreshToken: "sk-ant-ort01-new",
            expiresAt: expiresAt,
            to: """
            {
              "claudeAiOauth": {
                "accessToken": "old",
                "refreshToken": "old-refresh",
                "expiresAt": 1,
                "scopes": ["user:profile"]
              },
              "someFutureKey": {"keep": true}
            }
            """
        )

        #expect(updated == #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-new","expiresAt":1785200000000,"refreshToken":"sk-ant-ort01-new","scopes":["user:profile"]},"someFutureKey":{"keep":true}}"#)
        // `security` hex-encodes values containing newlines and Claude Code
        // cannot read those back, so the document must stay on one line.
        #expect(!(updated ?? "").contains("\n"))
    }

    @Test func claudeUsageClientRefreshesExpiredTokenBeforeQuerying() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"rt","expiresAt":1000}}"#,
            now: now,
            origin: .keychain
        )
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body: #"{"five_hour":{"utilization":48.0,"resets_at":"2026-07-27T17:00:00Z"}}"#
        )
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            tokenRefresher: StubClaudeTokenRefresher(accessToken: "fresh", expiresAt: now.addingTimeInterval(3_600)),
            now: { now }
        )

        let quota = await client.queryClaudeQuota(credentials: credentials)

        #expect(quota.success)
        #expect(await httpClient.requestCount() == 1)
        #expect(await httpClient.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func claudeUsageClientRetriesOnceWithRefreshedTokenAfterUnauthorized() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        // expiresAt far in the future: only the 401 can trigger the refresh.
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"revoked","refreshToken":"rt","expiresAt":1893456000000}}"#,
            now: now,
            origin: .keychain
        )
        let httpClient = SequencedHTTPClient(responses: [
            (401, "{}"),
            (200, #"{"five_hour":{"utilization":10.0,"resets_at":"2026-07-27T17:00:00Z"}}"#),
        ])
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            tokenRefresher: StubClaudeTokenRefresher(accessToken: "fresh", expiresAt: now.addingTimeInterval(3_600)),
            now: { now }
        )

        let quota = await client.queryClaudeQuota(credentials: credentials)

        #expect(quota.success)
        #expect(await httpClient.requestCount() == 2)
        #expect(await httpClient.lastRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func claudeUsageClientReportsRefreshFailureAlongsideUnauthorized() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"revoked","refreshToken":"rt","expiresAt":1893456000000}}"#,
            now: now,
            origin: .keychain
        )
        let client = ClaudeUsageClient(
            httpClient: CapturingHTTPClient(statusCode: 401, body: "{}"),
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            tokenRefresher: StubClaudeTokenRefresher(failure: .rejected(statusCode: 400)),
            now: { now }
        )

        let quota = await client.queryClaudeQuota(credentials: credentials)

        #expect(!quota.success)
        #expect(quota.credentialStatus == .expired)
        #expect(quota.error?.contains("Token refresh was rejected (HTTP 400)") == true)
    }

    @Test func claudeTokenRefresherPostsRefreshGrantAndPersistsRotatedDocument() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"rt-old","expiresAt":1000}}"#,
            now: now,
            origin: .keychain
        )
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body: #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#
        )
        let persister = RecordingCredentialPersister()
        let refresher = ClaudeTokenRefresher(
            httpClient: httpClient,
            persister: persister,
            endpoint: URL(string: "https://example.test/oauth/token")!,
            now: { now }
        )

        let result = await refresher.refresh(credentials)

        guard case .success(let refreshed) = result else {
            Issue.record("expected refresh to succeed, got \(result)")
            return
        }
        #expect(refreshed.accessToken == "at-new")
        #expect(refreshed.expiresAt == now.addingTimeInterval(28_800))
        #expect(refreshed.persisted)

        let request = await httpClient.lastRequest()
        #expect(request?.httpMethod == "POST")
        let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt-old"))
        #expect(body.contains("client_id=\(ClaudeTokenRefresher.clientID)"))

        // The rotated refresh token has to land back where Claude Code reads it,
        // otherwise the CLI keeps an invalidated one.
        let written = persister.lastDocument()
        #expect(written?.contains(#""refreshToken":"rt-new""#) == true)
        #expect(written?.contains(#""accessToken":"at-new""#) == true)
        #expect(persister.lastOrigin() == .keychain)
    }

    @Test func claudeTokenRefresherRefusesWithoutRefreshToken() async {
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"stale","expiresAt":1000}}"#,
            origin: .keychain
        )
        let refresher = ClaudeTokenRefresher(
            httpClient: CapturingHTTPClient(statusCode: 200, body: "{}"),
            persister: RecordingCredentialPersister(),
            endpoint: URL(string: "https://example.test/oauth/token")!
        )

        #expect(await refresher.refresh(credentials) == .failure(.notRefreshable))
    }

    @Test func claudeTokenRefresherRefusesWhenCredentialStoreIsNotWritable() async {
        let credentials = ClaudeCredentialResolver.parseClaudeCredentialsJSON(
            #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"rt-old","expiresAt":1000}}"#,
            origin: .keychain
        )
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body: #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#
        )
        let refresher = ClaudeTokenRefresher(
            httpClient: httpClient,
            persister: RejectingCredentialPersister(),
            endpoint: URL(string: "https://example.test/oauth/token")!
        )

        #expect(await refresher.refresh(credentials) == .failure(.notWritable))
        // The refresh token must not be spent when the rotated one cannot be
        // saved: doing so would invalidate Claude Code's own session.
        #expect(await httpClient.requestCount() == 0)
    }

    @Test func claudeUsageClientParsesModelScopedWeeklyWindows() async {
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-07-27T12:00:00Z")!
        let httpClient = CapturingHTTPClient(
            statusCode: 200,
            body:
            """
            {
              "five_hour": {"utilization": 48.0, "resets_at": "2026-07-27T17:00:00.521744+00:00"},
              "seven_day": {"utilization": 64.0, "resets_at": "2026-08-01T06:00:00.521764+00:00"},
              "seven_day_opus": {"utilization": 12.0, "resets_at": "2026-08-01T06:00:00Z"},
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "percent": 30.0,
                  "resets_at": "2026-08-01T06:00:00Z",
                  "is_active": true,
                  "scope": {"model": {"id": "claude-fable-5", "display_name": "Fable"}}
                }
              ],
              "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 320, "currency": "usd"}
            }
            """
        )
        let client = ClaudeUsageClient(
            httpClient: httpClient,
            endpoint: URL(string: "https://example.test/oauth/usage")!,
            requestGate: ClaudeUsageRequestGate(),
            now: { now }
        )

        let quota = await client.queryClaudeQuota(accessToken: "claude-secret")

        #expect(quota.tiers == [
            QuotaTier(name: "five_hour", utilization: 48.0, resetsAt: "2026-07-27T17:00:00Z"),
            QuotaTier(name: "seven_day", utilization: 64.0, resetsAt: "2026-08-01T06:00:00Z"),
            QuotaTier(name: "seven_day_fable", utilization: 30.0, resetsAt: "2026-08-01T06:00:00Z"),
            QuotaTier(name: "seven_day_opus", utilization: 12.0, resetsAt: "2026-08-01T06:00:00Z"),
        ])
        #expect(quota.extraUsage == "$3.20 of $50.00")

        let limits = ClaudeUsageLimitDisplay.usageLimits(from: quota)
        #expect(limits.map(\.title) == ["5h", "7d", "7d · Fable", "7d · Opus"])
    }

    @Test func resetTextPrecisionFollowsDistanceNotWindowLength() {
        let utc = TimeZone(secondsFromGMT: 0)!
        // A Friday.
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-08-07T12:00:00Z")!

        // ICU separates the time from AM/PM with a narrow no-break space
        // (U+202F), not the plain space a source literal carries.
        func reset(_ resetsAt: String) -> String? {
            UsageResetFormatting.text(forResetsAt: resetsAt, now: now, timeZone: utc)?
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }

        // Same calendar day: only the clock time carries information.
        #expect(reset("2026-08-07T21:40:00Z") == "9:40 PM")
        // Within the week: weekday plus time. Minutes are kept because reset
        // timestamps are not always on the hour.
        #expect(reset("2026-08-10T20:47:00Z") == "Mon 8:47 PM")
        #expect(reset("2026-08-13T06:00:00Z") == "Thu 6:00 AM")
        // Seven days out or more, the weekday would be ambiguous.
        #expect(reset("2026-08-14T06:00:00Z") == "Aug 14")
        #expect(reset("2026-09-03T06:00:00Z") == "Sep 3")
        // Already rolled over: fall through to the date rather than implying
        // a reset that has not happened.
        #expect(reset("2026-08-05T06:00:00Z") == "Aug 5")

        #expect(UsageResetFormatting.text(forResetsAt: nil, now: now, timeZone: utc) == nil)
        #expect(UsageResetFormatting.text(forResetsAt: "not-a-date", now: now, timeZone: utc) == nil)
    }

    @Test func resetTextUsesCalendarDayBoundaryNotRollingHours() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter.codexWithoutFractionalSeconds.date(from: "2026-08-07T23:00:00Z")!

        func reset(_ resetsAt: String) -> String? {
            UsageResetFormatting.text(forResetsAt: resetsAt, now: now, timeZone: utc)?
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }

        // 30 minutes away, but on the next calendar day: naming the day keeps
        // "11:30 PM vs 11:30 PM tomorrow" from being ambiguous.
        #expect(reset("2026-08-08T00:30:00Z")?.hasPrefix("Sat") == true)
        // Same day, 30 minutes earlier.
        #expect(reset("2026-08-07T23:30:00Z") == "11:30 PM")
    }

    @Test func menuBarRowsCarryPerWindowLimitsForSuccessfulQueries() async {
        let quota = SubscriptionQuota(
            tool: "claude_code",
            credentialStatus: .valid,
            credentialMessage: nil,
            success: true,
            tiers: [
                QuotaTier(name: "five_hour", utilization: 48, resetsAt: "2026-07-27T17:00:00Z"),
                QuotaTier(name: "seven_day", utilization: 64, resetsAt: "2026-08-01T06:00:00Z"),
            ],
            extraUsage: nil,
            error: nil,
            queriedAt: nil
        )
        let viewModel = await MenuBarUsageViewModel(
            agents: [.claudeCode(service: StubUsageTrackingService(toolID: "claude_code", quota: quota))]
        )

        await viewModel.refresh()

        let limits = await viewModel.rows.first?.limits ?? []
        #expect(limits.map(\.title) == ["5h", "7d"])
        #expect(limits.map(\.percentageText) == ["48%", "64%"])
    }

    @Test func menuBarRowsHaveNoLimitsWhenQueryFails() async {
        let viewModel = await MenuBarUsageViewModel(
            agents: [.claudeCode(service: StubUsageTrackingService(toolID: "claude_code", quota: .notFound(tool: "claude_code")))]
        )

        await viewModel.refresh()

        #expect(await viewModel.rows.first?.limits.isEmpty == true)
        #expect(await viewModel.rows.first?.detail == "Sign in required")
    }
}

private struct StubClaudeTokenRefresher: ClaudeTokenRefreshing {
    var result: Result<ClaudeRefreshedToken, ClaudeTokenRefreshError>

    init(accessToken: String, expiresAt: Date) {
        result = .success(ClaudeRefreshedToken(accessToken: accessToken, expiresAt: expiresAt, persisted: true))
    }

    init(failure: ClaudeTokenRefreshError) {
        result = .failure(failure)
    }

    func refresh(_ credentials: ClaudeCredentials) async -> Result<ClaudeRefreshedToken, ClaudeTokenRefreshError> {
        result
    }
}

private final class RecordingCredentialPersister: ClaudeCredentialPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [(String, ClaudeCredentialOrigin)] = []

    func persist(_ document: String, to origin: ClaudeCredentialOrigin) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        documents.append((document, origin))
        return true
    }

    func lastDocument() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return documents.last?.0
    }

    func lastOrigin() -> ClaudeCredentialOrigin? {
        lock.lock()
        defer { lock.unlock() }
        return documents.last?.1
    }
}

private struct RejectingCredentialPersister: ClaudeCredentialPersisting {
    func persist(_ document: String, to origin: ClaudeCredentialOrigin) -> Bool { false }
}

private actor SequencedHTTPClient: UsageHTTPClient {
    private let responses: [(statusCode: Int, body: String)]
    private var requests: [URLRequest] = []

    init(responses: [(statusCode: Int, body: String)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = min(requests.count, responses.count - 1)
        requests.append(request)
        let entry = responses[index]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: entry.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(entry.body.utf8), response)
    }

    func lastRequest() -> URLRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private final class ClaudeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private actor CapturingHTTPClient: CodexUsageHTTPClient {
    private var requests: [URLRequest] = []
    private let statusCode: Int
    private let body: String
    private let headerFields: [String: String]?

    init(statusCode: Int, body: String, headerFields: [String: String]? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.headerFields = headerFields
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        return (Data(body.utf8), response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct StubCursorCredentialResolver: CursorCredentialResolving {
    let credentials: CursorCredentials

    func readCursorCredentials() -> CursorCredentials {
        credentials
    }
}

private struct StubClaudeCredentialResolver: ClaudeCredentialResolving {
    let credentials: ClaudeCredentials

    func readClaudeCredentials() -> ClaudeCredentials {
        credentials
    }
}

private struct StubUsageTrackingService: UsageTrackingService {
    let toolID: String
    let quota: SubscriptionQuota
    var onQuery: (@Sendable () async -> Void)?

    func getSubscriptionQuota() async -> SubscriptionQuota {
        if let onQuery {
            await onQuery()
        }

        return quota
    }
}

private actor RefreshConcurrencyProbe {
    private var runningCount = 0
    private var maxRunning = 0

    func enter() {
        runningCount += 1
        maxRunning = max(maxRunning, runningCount)
    }

    func leave() {
        runningCount -= 1
    }

    func maxRunningCount() -> Int {
        maxRunning
    }
}

private actor CountingUsageServiceState {
    private let quota: SubscriptionQuota
    private var queries = 0

    init(quota: SubscriptionQuota) {
        self.quota = quota
    }

    func query() async -> SubscriptionQuota {
        queries += 1
        try? await Task.sleep(for: .milliseconds(50))
        return quota
    }

    func callCount() -> Int {
        queries
    }
}

private struct CountingUsageTrackingService: UsageTrackingService {
    let toolID: String
    let state: CountingUsageServiceState

    func getSubscriptionQuota() async -> SubscriptionQuota {
        await state.query()
    }
}
