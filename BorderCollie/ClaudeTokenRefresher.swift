import Foundation

struct ClaudeRefreshedToken: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date
    /// False when the new credential document could not be written back, which
    /// means Claude Code itself may now be holding a rotated-out refresh token.
    let persisted: Bool
}

enum ClaudeTokenRefreshError: Error, Equatable {
    /// No refresh token, no readable document, or no origin to write back to.
    case notRefreshable
    /// The credential store is readable but not writable, so a rotated refresh
    /// token could not be saved.
    case notWritable
    case rejected(statusCode: Int)
    case malformedResponse
    case transport(String)
}

protocol ClaudeTokenRefreshing: Sendable {
    func refresh(_ credentials: ClaudeCredentials) async -> Result<ClaudeRefreshedToken, ClaudeTokenRefreshError>
}

/// Exchanges Claude Code's refresh token for a fresh access token.
///
/// This is what keeps a background poller working: Anthropic's OAuth access
/// tokens are short-lived and the CLI only renews them while it is running, so
/// reading the stored token without refreshing it fails with 401 whenever the
/// user has not run `claude` recently.
///
/// Refreshes are serialized through this actor. Anthropic usually rotates the
/// refresh token, so two concurrent refreshes would leave one of the two
/// resulting tokens orphaned and could invalidate the CLI's session.
actor ClaudeTokenRefresher: ClaudeTokenRefreshing {
    static let shared = ClaudeTokenRefresher()

    /// Claude Code's public OAuth client ID.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let defaultEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private let httpClient: UsageHTTPClient
    private let persister: any ClaudeCredentialPersisting
    private let endpoint: URL
    private let now: @Sendable () -> Date

    private var inFlight: Task<ClaudeRefreshedToken, any Error>?
    private var lastRefreshed: ClaudeRefreshedToken?

    init(
        httpClient: UsageHTTPClient = URLSessionUsageHTTPClient(),
        persister: any ClaudeCredentialPersisting = ClaudeCredentialResolver(),
        endpoint: URL = ClaudeTokenRefresher.defaultEndpoint,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.httpClient = httpClient
        self.persister = persister
        self.endpoint = endpoint
        self.now = now
    }

    func refresh(_ credentials: ClaudeCredentials) async -> Result<ClaudeRefreshedToken, ClaudeTokenRefreshError> {
        guard credentials.canRefresh else {
            return .failure(.notRefreshable)
        }

        // A token minted moments ago by a parallel caller is still good.
        if let lastRefreshed, lastRefreshed.accessToken != credentials.accessToken,
           now().addingTimeInterval(60) < lastRefreshed.expiresAt {
            return .success(lastRefreshed)
        }

        if let inFlight {
            do {
                return .success(try await inFlight.value)
            } catch let error as ClaudeTokenRefreshError {
                return .failure(error)
            } catch {
                return .failure(.transport(error.localizedDescription))
            }
        }

        let task = Task<ClaudeRefreshedToken, any Error> { [httpClient, persister, endpoint, now] in
            try await Self.performRefresh(
                credentials: credentials,
                httpClient: httpClient,
                persister: persister,
                endpoint: endpoint,
                now: now
            )
        }
        inFlight = task

        defer { inFlight = nil }

        do {
            let refreshed = try await task.value
            lastRefreshed = refreshed
            return .success(refreshed)
        } catch let error as ClaudeTokenRefreshError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private static func performRefresh(
        credentials: ClaudeCredentials,
        httpClient: UsageHTTPClient,
        persister: any ClaudeCredentialPersisting,
        endpoint: URL,
        now: @Sendable () -> Date
    ) async throws -> ClaudeRefreshedToken {
        guard let refreshToken = credentials.refreshToken,
              let document = credentials.rawDocument,
              let origin = credentials.origin
        else {
            throw ClaudeTokenRefreshError.notRefreshable
        }

        // Anthropic rotates the refresh token, which invalidates the one Claude
        // Code has stored. Refreshing without being able to write the new one
        // back would break the CLI's session, so prove the store is writable —
        // by rewriting the document unchanged — before spending the token.
        guard persister.persist(document, to: origin) else {
            throw ClaudeTokenRefreshError.notWritable
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw ClaudeTokenRefreshError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeTokenRefreshError.rejected(statusCode: response.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(ClaudeOAuthRefreshResponse.self, from: data),
              !payload.accessToken.isEmpty
        else {
            throw ClaudeTokenRefreshError.malformedResponse
        }

        let expiresAt = now().addingTimeInterval(TimeInterval(payload.expiresIn ?? 3_600))

        var persisted = false
        if let updated = ClaudeCredentialResolver.documentApplying(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: expiresAt,
            to: document
        ) {
            persisted = persister.persist(updated, to: origin)
        }

        return ClaudeRefreshedToken(
            accessToken: payload.accessToken,
            expiresAt: expiresAt,
            persisted: persisted
        )
    }
}

private struct ClaudeOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
