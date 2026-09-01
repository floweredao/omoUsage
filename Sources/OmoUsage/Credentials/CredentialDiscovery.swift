import OmoUsageCore
import Foundation
import Darwin

enum CredentialSource: Equatable, Sendable {
    case environment
    case file
    case keychain
}

/// Exact store a credential was read from, so a rotated token is written
/// back where it came from instead of a different base store.
enum CredentialStorage: Equatable, Sendable {
    case file(URL)
    case keychain(service: String, account: String)
}

struct DiscoveredCredential: Equatable, Sendable, CustomStringConvertible {
    let provider: ProviderID
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
    let planName: String?
    let expiresAt: Date?
    let source: CredentialSource
    let oidcIssuer: String?
    let oidcClientID: String?
    let principalType: String?
    let principalID: String?
    let storage: CredentialStorage?

    init(
        provider: ProviderID,
        accessToken: String,
        refreshToken: String?,
        accountID: String?,
        planName: String?,
        expiresAt: Date?,
        source: CredentialSource,
        oidcIssuer: String? = nil,
        oidcClientID: String? = nil,
        principalType: String? = nil,
        principalID: String? = nil,
        storage: CredentialStorage? = nil
    ) {
        self.storage = storage
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.planName = planName
        self.expiresAt = expiresAt
        self.source = source
        self.oidcIssuer = oidcIssuer
        self.oidcClientID = oidcClientID
        self.principalType = principalType
        self.principalID = principalID
    }

    var description: String {
        "\(provider.displayName) credential (<redacted>)"
    }
}

enum CredentialDiscoveryError: Error, Equatable {
    case notFound(ProviderID)
    case malformed(ProviderID)
    case expired(ProviderID)
}

struct CredentialPaths: Sendable {
    let claude: URL
    let codex: URL
}

protocol KeychainReading: Sendable {
    func value(service: String, account: String) throws -> String?
}

protocol KeychainWriting: Sendable {
    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws
}

struct CredentialDiscovery: Sendable {
    static let claudeKeychainService = "Claude Code-credentials"
    static let claudeKeychainServices = [
        claudeKeychainService,
        "Claude Code-local-oauth-credentials",
        "Claude Code-staging-oauth-credentials",
        "Claude Code-custom-oauth-credentials"
    ]

    let paths: CredentialPaths
    let environment: [String: String]
    let keychain: any KeychainReading
    let providerKeychain: any ProviderKeychain
    let keychainWriter: (any KeychainWriting)?
    let homeDirectory: URL
    let commandPaths: [URL]

    init(
        paths: CredentialPaths,
        environment: [String: String],
        keychain: any KeychainReading,
        providerKeychain: (any ProviderKeychain)? = nil,
        keychainWriter: (any KeychainWriting)? = nil,
        homeDirectory: URL = Foundation.FileManager.default
            .homeDirectoryForCurrentUser,
        commandPaths: [URL] = [
            URL(filePath: "/opt/homebrew/bin/gh"),
            URL(filePath: "/usr/local/bin/gh")
        ]
    ) {
        self.paths = paths
        self.environment = environment
        self.keychain = keychain
        self.providerKeychain = providerKeychain
            ?? ReadOnlyProviderKeychain(reader: keychain)
        self.keychainWriter = keychainWriter
        self.homeDirectory = homeDirectory
        self.commandPaths = commandPaths
    }

    func claude(
        now: Date,
        allowingExpired: Bool = false
    ) throws -> DiscoveredCredential {
        let resolution = resolveClaudeCandidates(
            now: now,
            allowingExpired: allowingExpired
        )
        if let best = resolution.candidates.first {
            return best
        }
        if let failure = resolution.failure {
            throw failure
        }
        throw CredentialDiscoveryError.notFound(.claude)
    }

    /// Every parsable stored credential, in the order the runtime should
    /// try them. `claude(now:)` returns the first of these; a caller that
    /// can tell an auth rejection from a transport failure walks the rest.
    func claudeCandidates(
        now: Date,
        allowingExpired: Bool = false
    ) -> [DiscoveredCredential] {
        resolveClaudeCandidates(
            now: now,
            allowingExpired: allowingExpired
        ).candidates
    }

    private func resolveClaudeCandidates(
        now: Date,
        allowingExpired: Bool
    ) -> (
        candidates: [DiscoveredCredential],
        failure: CredentialDiscoveryError?
    ) {
        var candidates: [DiscoveredCredential] = []
        var candidateError: CredentialDiscoveryError?
        for service in Self.claudeKeychainServices {
            do {
                guard let raw = try keychain.value(
                    service: service,
                    account: ""
                ) else {
                    continue
                }
                candidates.append(
                    try parseClaude(
                        Data(raw.utf8),
                        source: .keychain,
                        storage: .keychain(
                            service: service,
                            account: ""
                        ),
                        now: now,
                        allowingExpired: allowingExpired
                    )
                )
            } catch let error as CredentialDiscoveryError {
                candidateError = betterClaudeFailure(
                    candidateError,
                    error
                )
            } catch {
                candidateError = betterClaudeFailure(
                    candidateError,
                    .malformed(.claude)
                )
            }
        }
        if Foundation.FileManager.default.fileExists(
            atPath: paths.claude.path
        ) {
            do {
                guard let data = try? Data(contentsOf: paths.claude)
                else {
                    throw CredentialDiscoveryError.malformed(.claude)
                }
                candidates.append(
                    try parseClaude(
                        data,
                        source: .file,
                        storage: .file(paths.claude),
                        now: now,
                        allowingExpired: allowingExpired
                    )
                )
            } catch let error as CredentialDiscoveryError {
                candidateError = betterClaudeFailure(
                    candidateError,
                    error
                )
            } catch {
                candidateError = betterClaudeFailure(
                    candidateError,
                    .malformed(.claude)
                )
            }
        }
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"]?.nonEmpty {
            candidates.append(
                DiscoveredCredential(
                    provider: .claude,
                    accessToken: token,
                    refreshToken: nil,
                    accountID: nil,
                    planName: nil,
                    expiresAt: nil,
                    source: .environment
                )
            )
        }
        return (candidates, candidateError)
    }

    /// Keeps the most actionable failure: a dead-but-real credential
    /// outranks an unusable store, which outranks nothing at all.
    private func betterClaudeFailure(
        _ current: CredentialDiscoveryError?,
        _ candidate: CredentialDiscoveryError
    ) -> CredentialDiscoveryError {
        guard let current else {
            return candidate
        }
        return claudeFailureRank(candidate) > claudeFailureRank(current)
            ? candidate
            : current
    }

    private func claudeFailureRank(
        _ error: CredentialDiscoveryError
    ) -> Int {
        switch error {
        case .expired:
            2
        case .malformed:
            1
        case .notFound:
            0
        }
    }

    /// Rewrites the stored Claude credential in place, keeping every field
    /// Claude Code owns (scopes, subscriptionType, rateLimitTier, …) so the
    /// CLI keeps working after OmoUsage rotates the token.
    func persistClaudeCredential(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        source: CredentialSource,
        storage: CredentialStorage? = nil
    ) throws {
        guard
            let location = storage ?? defaultClaudeStorage(for: source)
        else {
            return
        }
        let raw: Data
        switch location {
        case let .keychain(service, account):
            guard let text = try? keychain.value(
                service: service,
                account: account
            ) else {
                throw CredentialDiscoveryError.malformed(.claude)
            }
            raw = Data(text.utf8)
        case let .file(url):
            guard let data = try? Data(contentsOf: url) else {
                throw CredentialDiscoveryError.malformed(.claude)
            }
            raw = data
        }
        guard
            var root = try? UsageJSON.object(raw),
            var oauth = UsageJSON.object(root["claudeAiOauth"])
        else {
            throw CredentialDiscoveryError.malformed(.claude)
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        // Claude Code writes whole milliseconds; keep the file byte-shaped
        // the way the CLI expects to read it back.
        oauth["expiresAt"] = (
            expiresAt.timeIntervalSince1970 * 1_000
        ).rounded()
        root["claudeAiOauth"] = oauth
        let encoded = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        switch location {
        case let .keychain(service, account):
            guard
                let writer = keychainWriter,
                let text = String(data: encoded, encoding: .utf8)
            else {
                throw CredentialDiscoveryError.malformed(.claude)
            }
            try writer.setValue(
                text,
                service: service,
                account: account
            )
        case let .file(url):
            try writeAtomically(encoded, to: url)
        }
    }

    private func defaultClaudeStorage(
        for source: CredentialSource
    ) -> CredentialStorage? {
        switch source {
        case .environment:
            nil
        case .keychain:
            .keychain(
                service: Self.claudeKeychainService,
                account: ""
            )
        case .file:
            .file(paths.claude)
        }
    }

    func codex(now: Date) throws -> DiscoveredCredential {
        let resolution = resolveCodexCandidates(now: now)
        if let best = resolution.candidates.first {
            return best
        }
        if let failure = resolution.failure {
            throw failure
        }
        throw CredentialDiscoveryError.notFound(.codex)
    }

    func codexCandidates(now: Date) -> [DiscoveredCredential] {
        resolveCodexCandidates(now: now).candidates
    }

    private func resolveCodexCandidates(
        now: Date
    ) -> (
        candidates: [DiscoveredCredential],
        failure: CredentialDiscoveryError?
    ) {
        var candidates: [DiscoveredCredential] = []
        var candidateError: CredentialDiscoveryError?
        if Foundation.FileManager.default.fileExists(
            atPath: paths.codex.path
        ) {
            do {
                let data = try Data(contentsOf: paths.codex)
                candidates.append(
                    try parseCodex(
                        data,
                        source: .file,
                        storage: .file(paths.codex),
                        now: now
                    )
                )
            } catch let error as CredentialDiscoveryError {
                candidateError = error
            } catch {
                candidateError = .malformed(.codex)
            }
        }
        for service in ["Codex Auth", "Codex", "OpenAI Codex"] {
            do {
                guard let raw = try keychain.value(
                    service: service,
                    account: ""
                ) else {
                    continue
                }
                candidates.append(
                    try parseCodex(
                        Data(raw.utf8),
                        source: .keychain,
                        storage: .keychain(
                            service: service,
                            account: ""
                        ),
                        now: now
                    )
                )
            } catch let error as CredentialDiscoveryError {
                candidateError = error
            } catch {
                candidateError = .malformed(.codex)
            }
        }
        return (candidates, candidateError)
    }

    func persistCodexCredential(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        lastRefresh: Date,
        storage: CredentialStorage?
    ) throws {
        guard let storage else {
            throw CredentialDiscoveryError.malformed(.codex)
        }
        let raw: Data
        switch storage {
        case let .file(url):
            guard let data = try? Data(contentsOf: url) else {
                throw CredentialDiscoveryError.malformed(.codex)
            }
            raw = data
        case let .keychain(service, account):
            guard let text = try? keychain.value(
                service: service,
                account: account
            ) else {
                throw CredentialDiscoveryError.malformed(.codex)
            }
            raw = Data(text.utf8)
        }
        guard
            var root = try? UsageJSON.object(raw),
            var tokens = UsageJSON.object(root["tokens"])
        else {
            throw CredentialDiscoveryError.malformed(.codex)
        }
        tokens["access_token"] = accessToken
        if let refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken {
            tokens["id_token"] = idToken
        }
        root["tokens"] = tokens
        root["last_refresh"] = lastRefresh.ISO8601Format()
        let encoded = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        switch storage {
        case let .file(url):
            do {
                try writeAtomically(encoded, to: url)
            } catch {
                throw CredentialDiscoveryError.malformed(.codex)
            }
        case let .keychain(service, account):
            guard
                let keychainWriter,
                let text = String(data: encoded, encoding: .utf8)
            else {
                throw CredentialDiscoveryError.malformed(.codex)
            }
            do {
                try keychainWriter.setValue(
                    text,
                    service: service,
                    account: account
                )
            } catch {
                throw CredentialDiscoveryError.malformed(.codex)
            }
        }
    }

    func antigravity(now: Date) throws -> DiscoveredCredential {
        guard let raw = try keychain.value(
            service: "gemini",
            account: "antigravity"
        ) else {
            throw CredentialDiscoveryError.notFound(.antigravity)
        }
        let decoded = Data(base64Encoded: raw) ?? Data(raw.utf8)
        return try parseAntigravity(decoded, now: now)
    }

    func persistGrokCredential(
        accountID: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        idToken: String? = nil
    ) throws {
        let url = grokHome.appending(path: "auth.json")
        guard
            let data = try? Data(contentsOf: url),
            var object = try? UsageJSON.object(data),
            var entry = UsageJSON.object(object[accountID])
        else {
            throw CredentialDiscoveryError.malformed(.grok)
        }
        entry["key"] = accessToken
        entry["refresh_token"] = refreshToken
        entry["expires_at"] = expiresAt.ISO8601Format()
        // Only overwrite when the exchange returned one; a response that
        // omits `id_token` must leave the stored identity intact.
        if let idToken {
            entry["id_token"] = idToken
        }
        object[accountID] = entry
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        let directory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let temporaryURL = directory.appending(
            path: ".auth.json.\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: encoded,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialDiscoveryError.malformed(.grok)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CredentialDiscoveryError.malformed(.grok)
        }
    }

    static func live(
        home: URL = Foundation.FileManager.default
            .homeDirectoryForCurrentUser,
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        keychain: any KeychainReading = SecurityKeychainReader()
    ) -> CredentialDiscovery {
        let codexHome: URL
        if let path = environment["CODEX_HOME"]?.nonEmpty {
            codexHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            codexHome = home.appending(
                path: ".codex",
                directoryHint: URL.DirectoryHint.isDirectory
            )
        }
        let claudeHome: URL
        if
            let path = environment["CLAUDE_CONFIG_DIR"]?.nonEmpty,
            path.hasPrefix("/")
        {
            claudeHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            claudeHome = home.appending(
                path: ".claude",
                directoryHint: URL.DirectoryHint.isDirectory
            )
        }
        return CredentialDiscovery(
            paths: CredentialPaths(
                claude: claudeHome.appending(
                    path: ".credentials.json"
                ),
                codex: codexHome.appending(path: "auth.json")
            ),
            environment: environment,
            keychain: keychain,
            providerKeychain: SecurityProviderKeychain(),
            keychainWriter: SecurityKeychainWriter(),
            homeDirectory: home,
            commandPaths: [
                URL(filePath: "/opt/homebrew/bin/gh"),
                URL(filePath: "/usr/local/bin/gh")
            ]
        )
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialDiscoveryError.malformed(.claude)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw CredentialDiscoveryError.malformed(.claude)
        }
    }

    private func parseClaude(
        _ data: Data,
        source: CredentialSource,
        storage: CredentialStorage?,
        now: Date,
        allowingExpired: Bool = false
    ) throws -> DiscoveredCredential {
        guard
            let root = try? UsageJSON.object(data),
            let oauth = UsageJSON.object(root["claudeAiOauth"]),
            let accessToken = (oauth["accessToken"] as? String)?.nonEmpty
        else {
            throw CredentialDiscoveryError.malformed(.claude)
        }
        let expiresAt = credentialDate(oauth["expiresAt"])
        if !allowingExpired, let expiresAt, expiresAt <= now {
            throw CredentialDiscoveryError.expired(.claude)
        }
        let plan = claudePlanName(oauth)
        return DiscoveredCredential(
            provider: .claude,
            accessToken: accessToken,
            refreshToken: (oauth["refreshToken"] as? String)?.nonEmpty,
            accountID: nil,
            planName: plan,
            expiresAt: expiresAt,
            source: source,
            storage: storage
        )
    }

    private func claudePlanName(
        _ oauth: [String: Any]
    ) -> String? {
        guard
            let subscription = (
                oauth["subscriptionType"] as? String
            )?.nonEmpty
        else {
            return nil
        }
        let plan = subscription.capitalized
        guard
            let tier = (
                oauth["rateLimitTier"] as? String
            )?.nonEmpty?.lowercased(),
            tier.contains("_\(subscription.lowercased())_"),
            let suffix = tier.split(separator: "_").last,
            suffix.last == "x",
            let multiplier = Int(suffix.dropLast()),
            multiplier > 0
        else {
            return plan
        }
        return "\(plan) \(multiplier)x"
    }

    private func parseCodex(
        _ data: Data,
        source: CredentialSource,
        storage: CredentialStorage?,
        now: Date
    ) throws -> DiscoveredCredential {
        guard
            let root = try? UsageJSON.object(data),
            root["auth_mode"] as? String == "chatgpt",
            let tokens = UsageJSON.object(root["tokens"]),
            let accessToken = (tokens["access_token"] as? String)?.nonEmpty
        else {
            throw CredentialDiscoveryError.malformed(.codex)
        }
        return DiscoveredCredential(
            provider: .codex,
            accessToken: accessToken,
            refreshToken: (tokens["refresh_token"] as? String)?.nonEmpty,
            accountID: (tokens["account_id"] as? String)?.nonEmpty,
            planName: nil,
            expiresAt: codexJWTExpiration(accessToken),
            source: source,
            storage: storage
        )
    }

    private func codexJWTExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(
            repeating: "=",
            count: (4 - payload.count % 4) % 4
        )
        guard
            let data = Data(base64Encoded: payload),
            let object = try? UsageJSON.object(data),
            let expiration = UsageJSON.number(object["exp"])
        else {
            return nil
        }
        return Date(timeIntervalSince1970: expiration)
    }

    private func parseAntigravity(
        _ data: Data,
        now: Date
    ) throws -> DiscoveredCredential {
        guard
            let root = try? UsageJSON.object(data),
            let accessToken = (
                root["access_token"] as? String
                ?? root["accessToken"] as? String
                ?? root["token"] as? String
            )?.nonEmpty
        else {
            throw CredentialDiscoveryError.malformed(.antigravity)
        }
        let expiresAt = credentialDate(
            root["expiry"] ?? root["expires_at"] ?? root["expiry_date"]
        )
        if let expiresAt, expiresAt <= now {
            throw CredentialDiscoveryError.expired(.antigravity)
        }
        return DiscoveredCredential(
            provider: .antigravity,
            accessToken: accessToken,
            refreshToken: (
                root["refresh_token"] as? String
                ?? root["refreshToken"] as? String
            )?.nonEmpty,
            accountID: nil,
            planName: nil,
            expiresAt: expiresAt,
            source: .keychain
        )
    }

    private func credentialDate(_ value: Any?) -> Date? {
        guard var seconds = UsageJSON.number(value) else {
            return UsageJSON.date(value)
        }
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        return UsageJSON.date(timeIntervalSince1970: seconds)
    }
}

enum SecretRedactor {
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "<redacted>")
            }
    }
}

private struct ReadOnlyProviderKeychain: ProviderKeychain {
    let reader: any KeychainReading
    func value(service: String, account: String) throws -> String? {
        try reader.value(service: service, account: account)
    }
    func set(_ value: String, service: String, account: String) throws {
        throw KeychainReadError(status: errSecReadOnly)
    }
    func remove(service: String, account: String) throws {
        throw KeychainReadError(status: errSecReadOnly)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
