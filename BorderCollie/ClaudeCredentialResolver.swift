import Foundation
import Security

protocol ClaudeCredentialResolving: Sendable {
    func readClaudeCredentials() -> ClaudeCredentials
}

/// Writes a refreshed credential document back where it came from.
///
/// Anthropic rotates the refresh token on most refreshes, which invalidates the
/// one Claude Code still has on disk. Refreshing without writing back would
/// therefore break the user's actual CLI session, so a refresher must persist.
protocol ClaudeCredentialPersisting: Sendable {
    func persist(_ document: String, to origin: ClaudeCredentialOrigin) -> Bool
}

/// Where a Claude Code credential document was read from, and where a refreshed
/// one has to be written back.
enum ClaudeCredentialOrigin: Equatable, Sendable {
    case file(URL)
    case keychain
}

struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?
    let origin: ClaudeCredentialOrigin?
    /// The full credential document as read, so a refresh can round-trip keys
    /// BorderCollie does not model rather than dropping them on write-back.
    let rawDocument: String?
    let status: CredentialStatus
    let message: String?

    init(
        accessToken: String?,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = [],
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        origin: ClaudeCredentialOrigin? = nil,
        rawDocument: String? = nil,
        status: CredentialStatus,
        message: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.origin = origin
        self.rawDocument = rawDocument
        self.status = status
        self.message = message
    }

    /// True when the access token is at or near its expiry and a refresh should
    /// happen before spending a request on a token the server will reject.
    func needsRefresh(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else {
            return false
        }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    var canRefresh: Bool {
        guard let refreshToken, !refreshToken.isEmpty, rawDocument != nil, origin != nil else {
            return false
        }
        return true
    }
}

struct ClaudeCredentialResolver: ClaudeCredentialResolving, ClaudeCredentialPersisting {
    private static let keychainTimeoutSeconds = 2.0
    static let keychainServiceName = "Claude Code-credentials"

    private let credentialsFileURL: URL
    private let now: @Sendable () -> Date
    private let keychainReader: @Sendable () -> String?
    private let keychainWriter: @Sendable (String) -> Bool

    init(
        credentialsFileURL: URL = ClaudeCredentialResolver.defaultCredentialsFileURL(),
        now: @escaping @Sendable () -> Date = Date.init,
        keychainReader: @escaping @Sendable () -> String? = ClaudeCredentialResolver.readClaudeCredentialsFromKeychain,
        keychainWriter: @escaping @Sendable (String) -> Bool = ClaudeCredentialResolver.writeClaudeCredentialsToKeychain
    ) {
        self.credentialsFileURL = credentialsFileURL
        self.now = now
        self.keychainReader = keychainReader
        self.keychainWriter = keychainWriter
    }

    /// Claude Code prefers an on-disk credentials file when one exists and only
    /// falls back to the login keychain, so resolve in that order.
    nonisolated func readClaudeCredentials() -> ClaudeCredentials {
        if FileManager.default.fileExists(atPath: credentialsFileURL.path) {
            let fileResult = readClaudeCredentialsFromFile()
            if fileResult.accessToken != nil {
                return fileResult
            }
        }

        if let keychainValue = keychainReader()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainValue.isEmpty {
            return Self.parseClaudeCredentialsJSON(keychainValue, now: now(), origin: .keychain)
        }

        return ClaudeCredentials(accessToken: nil, status: .notFound, message: nil)
    }

    nonisolated func persist(_ document: String, to origin: ClaudeCredentialOrigin) -> Bool {
        switch origin {
        case .keychain:
            return keychainWriter(document)
        case .file(let url):
            do {
                try document.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
    }

    private nonisolated func readClaudeCredentialsFromFile() -> ClaudeCredentials {
        do {
            let content = try String(contentsOf: credentialsFileURL, encoding: .utf8)
            return Self.parseClaudeCredentialsJSON(content, now: now(), origin: .file(credentialsFileURL))
        } catch {
            return ClaudeCredentials(
                accessToken: nil,
                status: .parseError,
                message: "Failed to read Claude Code credentials: \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func parseClaudeCredentialsJSON(
        _ content: String,
        now: Date = Date(),
        origin: ClaudeCredentialOrigin? = nil
    ) -> ClaudeCredentials {
        // `security -w` hex-encodes any password whose bytes are not plain
        // printable ASCII, so a hex blob is a normal shape for this document.
        let normalized = decodeHexEncodedJSON(content) ?? content

        let payload: ClaudeCredentialsJSON
        do {
            payload = try JSONDecoder().decode(ClaudeCredentialsJSON.self, from: Data(normalized.utf8))
        } catch {
            return ClaudeCredentials(
                accessToken: nil,
                status: .parseError,
                message: "Failed to parse Claude Code credentials: \(error.localizedDescription)"
            )
        }

        guard let oauth = payload.claudeAiOauth else {
            return ClaudeCredentials(
                accessToken: nil,
                status: .notFound,
                message: "Claude Code is not using Claude.ai OAuth credentials"
            )
        }

        guard let accessToken = normalizeAccessToken(oauth.accessToken), !accessToken.isEmpty else {
            return ClaudeCredentials(
                accessToken: nil,
                status: .parseError,
                message: "Claude Code access token is empty or missing"
            )
        }

        let refreshToken = oauth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
        let isExpired = expiresAt.map { $0 <= now } ?? false
        let hasRefreshToken = !(refreshToken ?? "").isEmpty && origin != nil

        // An expired access token backed by a refresh token is the normal steady
        // state for a long-running poller, not a credential problem: report it as
        // valid and let the usage client mint a new one.
        let status: CredentialStatus = (isExpired && !hasRefreshToken) ? .expired : .valid

        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: (refreshToken?.isEmpty ?? true) ? nil : refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier,
            origin: origin,
            rawDocument: normalized,
            status: status,
            message: status == .expired ? "Claude Code OAuth token has expired" : nil
        )
    }

    /// Rewrites `claudeAiOauth` inside an existing document, leaving every other
    /// key untouched. Output is minified: `security` hex-encodes values
    /// containing newlines, and Claude Code cannot read those back.
    nonisolated static func documentApplying(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        to document: String
    ) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(document.utf8)),
            var root = object as? [String: Any]
        else {
            return nil
        }

        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = expiresAt.millisecondsSince1970
        root["claudeAiOauth"] = oauth

        guard
            let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return json
    }

    private nonisolated static func normalizeAccessToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        guard trimmed.lowercased().hasPrefix("bearer ") else {
            return trimmed
        }

        return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func decodeHexEncodedJSON(_ content: String) -> String? {
        var hex = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }

        guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }

        return String(bytes: bytes, encoding: .utf8)
    }

    nonisolated static func defaultCredentialsFileURL() -> URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configDir, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    nonisolated static func readClaudeCredentialsFromKeychain() -> String? {
        if let value = readKeychainItemViaSecurityFramework() {
            return value
        }

        return readKeychainItemViaSecurityCLI()
    }

    private nonisolated static func readKeychainItemViaSecurityFramework() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Fallback for keychain items whose ACL already trusts `/usr/bin/security`
    /// but not this app.
    private nonisolated static func readKeychainItemViaSecurityCLI() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainServiceName, "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + keychainTimeoutSeconds) == .success else {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: output, encoding: .utf8)
    }

    /// Updates the existing item in place via the Security framework. The
    /// `security` CLI is deliberately not used for writes: it would put the
    /// refresh token in `argv`, where any local process can read it from `ps`.
    nonisolated static func writeClaudeCredentialsToKeychain(_ document: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(document.utf8)]

        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }
}

private struct ClaudeCredentialsJSON: Decodable {
    let claudeAiOauth: ClaudeOAuthJSON?
}

private struct ClaudeOAuthJSON: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Double?
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scopes
        case subscriptionType
        case subscriptionTypeSnake = "subscription_type"
        case rateLimitTier
        case rateLimitTierSnake = "rate_limit_tier"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes)
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
            ?? container.decodeIfPresent(String.self, forKey: .subscriptionTypeSnake)
        rateLimitTier = try container.decodeIfPresent(String.self, forKey: .rateLimitTier)
            ?? container.decodeIfPresent(String.self, forKey: .rateLimitTierSnake)
    }
}
