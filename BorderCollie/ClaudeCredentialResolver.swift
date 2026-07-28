import Foundation

protocol ClaudeCredentialResolving: Sendable {
    func readClaudeCredentials() -> ClaudeCredentials
}

struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String?
    let status: CredentialStatus
    let message: String?
}

struct ClaudeCredentialResolver: ClaudeCredentialResolving {
    private static let keychainTimeoutSeconds = 2.0
    private static let keychainServiceName = "Claude Code-credentials"

    private let credentialsFileURL: URL
    private let now: @Sendable () -> Date
    private let keychainReader: @Sendable () -> String?

    init(
        credentialsFileURL: URL = ClaudeCredentialResolver.defaultCredentialsFileURL(),
        now: @escaping @Sendable () -> Date = Date.init,
        keychainReader: @escaping @Sendable () -> String? = ClaudeCredentialResolver.readClaudeCredentialsFromKeychain
    ) {
        self.credentialsFileURL = credentialsFileURL
        self.now = now
        self.keychainReader = keychainReader
    }

    nonisolated func readClaudeCredentials() -> ClaudeCredentials {
        if let keychainJSON = keychainReader()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainJSON.isEmpty {
            return Self.parseClaudeCredentialsJSON(keychainJSON, now: now())
        }

        return readClaudeCredentialsFromFile()
    }

    private nonisolated func readClaudeCredentialsFromFile() -> ClaudeCredentials {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            return ClaudeCredentials(
                accessToken: nil,
                status: .notFound,
                message: nil
            )
        }

        do {
            let content = try String(contentsOf: credentialsFileURL, encoding: .utf8)
            return Self.parseClaudeCredentialsJSON(content, now: now())
        } catch {
            return ClaudeCredentials(
                accessToken: nil,
                status: .parseError,
                message: "Failed to read Claude Code credentials: \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func parseClaudeCredentialsJSON(_ content: String, now: Date = Date()) -> ClaudeCredentials {
        let payload: ClaudeCredentialsJSON
        do {
            payload = try JSONDecoder().decode(ClaudeCredentialsJSON.self, from: Data(content.utf8))
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

        guard let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            return ClaudeCredentials(
                accessToken: nil,
                status: .parseError,
                message: "Claude Code access token is empty or missing"
            )
        }

        if let expiresAtMilliseconds = oauth.expiresAt,
           Date(timeIntervalSince1970: expiresAtMilliseconds / 1_000) <= now {
            return ClaudeCredentials(
                accessToken: accessToken,
                status: .expired,
                message: "Claude Code OAuth token has expired"
            )
        }

        return ClaudeCredentials(
            accessToken: accessToken,
            status: .valid,
            message: nil
        )
    }

    private nonisolated static func defaultCredentialsFileURL() -> URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configDir, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    private nonisolated static func readClaudeCredentialsFromKeychain() -> String? {
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
}

private struct ClaudeCredentialsJSON: Decodable {
    let claudeAiOauth: ClaudeOAuthJSON?
}

private struct ClaudeOAuthJSON: Decodable {
    let accessToken: String?
    let expiresAt: Double?
}
