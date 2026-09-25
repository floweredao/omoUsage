import OmoUsageCore
import CryptoKit
import Foundation
import Darwin

enum CredentialSource: String, Equatable, Codable, Sendable {
    case environment
    case file
    case keychain
}

/// Exact store a credential was read from, so a rotated token is written
/// back where it came from instead of a different base store.
enum CredentialStorage: Equatable, Sendable {
    case file(URL)
    /// Logical Keychain origin. For protected Claude services the Security
    /// reader/writer resolve this exact origin to the explicitly authorized
    /// app-owned raw mirror; they never access the foreign item in background.
    case keychain(service: String, account: String)
    /// An OmoUsage-owned snapshot secret, addressed by the account that
    /// captured it. A rotation lands on exactly this account's Keychain
    /// item and never touches the companion tool's own store.
    case accountSnapshot(AccountProviderID)
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
    /// App-owned OIDC registration material; serialized only inside the Keychain secret.
    let oidcClientSecret: String?
    let oidcClientSecretExpiresAt: Date?
    let principalType: String?
    let principalID: String?
    let storage: CredentialStorage?
    /// Local identity metadata only; never copied into usage or sync models.
    let email: String?

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
        oidcClientSecret: String? = nil,
        oidcClientSecretExpiresAt: Date? = nil,
        principalType: String? = nil,
        principalID: String? = nil,
        storage: CredentialStorage? = nil,
        email: String? = nil
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
        self.oidcClientSecret = oidcClientSecret
        self.oidcClientSecretExpiresAt = oidcClientSecretExpiresAt
        self.principalType = principalType
        self.principalID = principalID
        self.email = email
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

/// App-owned copy of one account's companion credential, captured when the
/// account is added and read back on every later fetch. Without it a second
/// account would re-run discovery and land on whichever credential the
/// companion CLI happens to hold right now, which is the first account's.
struct CredentialSnapshot: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    static let currentVersion = 1

    let version: Int
    let provider: ProviderID
    let accessToken: String
    let refreshToken: String?
    /// The provider's own account identifier (Codex `account_id`, Grok
    /// auth-store key, Devin server URL), not the app's `AccountID`.
    let accountReference: String?
    let planName: String?
    let expiresAt: Date?
    let source: CredentialSource
    let oidcIssuer: String?
    let oidcClientID: String?
    let oidcClientSecret: String?
    let oidcClientSecretExpiresAt: Date?
    let principalType: String?
    let principalID: String?
    let email: String?

    init(
        version: Int = CredentialSnapshot.currentVersion,
        provider: ProviderID,
        accessToken: String,
        refreshToken: String?,
        accountReference: String?,
        planName: String?,
        expiresAt: Date?,
        source: CredentialSource,
        oidcIssuer: String? = nil,
        oidcClientID: String? = nil,
        oidcClientSecret: String? = nil,
        oidcClientSecretExpiresAt: Date? = nil,
        principalType: String? = nil,
        principalID: String? = nil,
        email: String? = nil
    ) {
        self.version = version
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountReference = accountReference
        self.planName = planName
        self.expiresAt = expiresAt
        self.source = source
        self.oidcIssuer = oidcIssuer
        self.oidcClientID = oidcClientID
        self.oidcClientSecret = oidcClientSecret
        self.oidcClientSecretExpiresAt = oidcClientSecretExpiresAt
        self.principalType = principalType
        self.principalID = principalID
        self.email = email
    }

    init(_ credential: DiscoveredCredential) {
        self.init(
            provider: credential.provider,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accountReference: credential.accountID,
            planName: credential.planName,
            expiresAt: credential.expiresAt,
            source: credential.source,
            oidcIssuer: credential.oidcIssuer,
            oidcClientID: credential.oidcClientID,
            oidcClientSecret: credential.oidcClientSecret,
            oidcClientSecretExpiresAt: credential.oidcClientSecretExpiresAt,
            principalType: credential.principalType,
            principalID: credential.principalID,
            email: credential.email
        )
    }

    /// Decodes a stored secret. A snapshot that does not describe the
    /// provider being asked for is malformed rather than usable, so a
    /// misfiled item can never authenticate somewhere else.
    init(encodedSecret: String, provider: ProviderID) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard
            let decoded = try? decoder.decode(
                CredentialSnapshot.self,
                from: Data(encodedSecret.utf8)
            ),
            decoded.version == Self.currentVersion,
            decoded.provider == provider,
            !decoded.accessToken.isEmpty
        else {
            throw CredentialDiscoveryError.malformed(provider)
        }
        self = decoded
    }

    func encodedSecret() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard
            let data = try? encoder.encode(self),
            let text = String(data: data, encoding: .utf8)
        else {
            throw CredentialDiscoveryError.malformed(provider)
        }
        return text
    }

    func credential(storage: CredentialStorage) -> DiscoveredCredential {
        DiscoveredCredential(
            provider: provider,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountReference,
            planName: planName,
            expiresAt: expiresAt,
            source: source,
            oidcIssuer: oidcIssuer,
            oidcClientID: oidcClientID,
            oidcClientSecret: oidcClientSecret,
            oidcClientSecretExpiresAt: oidcClientSecretExpiresAt,
            principalType: principalType,
            principalID: principalID,
            storage: storage,
            email: email
        )
    }

    /// Everything the provider owns (issuer, client id, principal, plan)
    /// survives a rotation; only the token material moves.
    func rotated(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: provider,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountReference: accountReference,
            planName: planName,
            expiresAt: expiresAt,
            source: source,
            oidcIssuer: oidcIssuer,
            oidcClientID: oidcClientID,
            oidcClientSecret: oidcClientSecret,
            oidcClientSecretExpiresAt: oidcClientSecretExpiresAt,
            principalType: principalType,
            principalID: principalID,
            email: identityEmail
        )
    }

    private var identityEmail: String? {
        email ?? (provider == .codex
            ? CredentialDiscovery.codexIdentityEmail(accessToken)
            : nil)
    }

    var maskedIdentity: String? {
        MaskedAccountIdentity.email(identityEmail)
    }

    /// A companion relogin may repair this account, but must never switch
    /// its owner or roll a newer app-owned token back to an older CLI copy.
    func isNewerCodexCredential(than stored: CredentialSnapshot) -> Bool {
        guard
            provider == .codex, stored.provider == .codex,
            let accountReference, !accountReference.isEmpty,
            accountReference == stored.accountReference,
            let expiresAt, let storedExpiration = stored.expiresAt
        else { return false }
        return expiresAt > storedExpiration
    }

    var description: String {
        "\(provider.displayName) credential snapshot (<redacted>)"
    }

    var debugDescription: String { description }
}

/// Reads and writes snapshot secrets under the Keychain identity
/// `ProviderAPIKeyStore` already owns: one generic-password item per
/// account/provider pair, so every account's secret is addressable on its
/// own and a write can only ever land on one of them.
struct ProviderCredentialSnapshotStore: Sendable {
    let keychain: any ProviderKeychain
    let serviceName: String

    init(
        keychain: any ProviderKeychain,
        serviceName: String = ProviderAPIKeyStore.serviceName
    ) {
        self.keychain = keychain
        self.serviceName = serviceName
    }

    static func account(for identity: AccountProviderID) -> String {
        "\(identity.providerID.rawValue)/\(identity.accountID.rawValue)"
    }

    func snapshot(
        for identity: AccountProviderID
    ) throws -> CredentialSnapshot? {
        let stored: String?
        do {
            stored = try keychain.value(
                service: serviceName,
                account: Self.account(for: identity)
            )
        } catch {
            // A denied or ambiguous exact lookup must not widen into a
            // different account's secret, and must not fall back to
            // whatever the companion CLI is holding.
            throw CredentialDiscoveryError.notFound(identity.providerID)
        }
        guard let stored, !stored.isEmpty else { return nil }
        return try CredentialSnapshot(
            encodedSecret: stored,
            provider: identity.providerID
        )
    }

    func save(
        _ snapshot: CredentialSnapshot,
        for identity: AccountProviderID
    ) throws {
        guard snapshot.provider == identity.providerID else {
            throw CredentialDiscoveryError.malformed(identity.providerID)
        }
        let secret = try snapshot.encodedSecret()
        do {
            try keychain.set(
                secret,
                service: serviceName,
                account: Self.account(for: identity)
            )
        } catch {
            throw CredentialDiscoveryError.malformed(identity.providerID)
        }
    }
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
    static func claudeLoginDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: "Library/Application Support/OmoUsage/Claude")
    }

    // Claude Code's published CLI keys a configured directory by the first
    // eight SHA-256 hex characters of its NFC path (cli.js 2.1.69).
    static let claudeLoginKeychainService: String = {
        let path = claudeLoginDirectory().path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(claudeKeychainService)-\(digest.prefix(8))"
    }()

    static let claudeKeychainServices = [
        claudeLoginKeychainService,
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
        accountID: AccountID = .legacy,
        now: Date,
        allowingExpired: Bool = false
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            return try snapshotCredential(
                for: .claude,
                accountID: accountID,
                now: now,
                allowingExpired: allowingExpired
            )
        }
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
        accountID: AccountID = .legacy,
        now: Date,
        allowingExpired: Bool = false
    ) -> [DiscoveredCredential] {
        guard accountID == .legacy else {
            // A nonlegacy account has exactly one credential: its own
            // snapshot. Walking the local stores here would hand it the
            // credential another account already claimed.
            return (try? snapshotCredential(
                for: .claude,
                accountID: accountID,
                now: now,
                allowingExpired: allowingExpired
            )).map { [$0] } ?? []
        }
        return resolveClaudeCandidates(
            now: now,
            allowingExpired: allowingExpired
        ).candidates
    }

    private func resolveClaudeCandidates(
        now: Date,
        allowingExpired: Bool
    ) -> (
        candidates: [DiscoveredCredential],
        failure: (any Error)?
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
            } catch let error as KeychainReadError {
                // An inaccessible exact authorization must not select another
                // service, a file, or an environment token instead.
                return ([], error)
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

    /// Rewrites the stored Claude credential, keeping every field Claude Code
    /// owns (scopes, subscriptionType, rateLimitTier, …). Protected Keychain
    /// origins rotate only the authorized app-owned mirror, not the CLI item.
    func persistClaudeCredential(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        source: CredentialSource,
        storage: CredentialStorage? = nil
    ) throws {
        if case let .accountSnapshot(identity) = storage {
            try rotateSnapshot(
                identity,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )
            return
        }
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
        case .accountSnapshot:
            // Handled above; a snapshot rotation never reaches the
            // companion tool's own credential file.
            throw CredentialDiscoveryError.malformed(.claude)
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
        case .accountSnapshot:
            throw CredentialDiscoveryError.malformed(.claude)
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

    func codex(
        accountID: AccountID = .legacy,
        now: Date
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            return try codexSnapshotCredential(
                accountID: accountID,
                now: now
            )
        }
        let legacyIdentity = AccountProviderID(
            accountID: .legacy,
            providerID: .codex
        )
        if let snapshot = try snapshotStore.snapshot(for: legacyIdentity) {
            return try reconciledLegacyCodexCredential(snapshot, now: now)
        }
        return try mutableCodexCredential(now: now)
    }

    /// Reads only Codex's mutable companion stores. This deliberately
    /// bypasses the legacy pin for Add Account and reconnect fingerprinting.
    private func mutableCodexCredential(
        now: Date
    ) throws -> DiscoveredCredential {
        let resolution = resolveCodexCandidates(now: now)
        if let best = resolution.candidates.first {
            return best
        }
        if let failure = resolution.failure {
            throw failure
        }
        throw CredentialDiscoveryError.notFound(.codex)
    }

    func codexCandidates(
        accountID: AccountID = .legacy,
        now: Date
    ) -> [DiscoveredCredential] {
        guard accountID == .legacy else {
            return (try? codexSnapshotCredential(
                accountID: accountID,
                now: now
            )).map { [$0] } ?? []
        }
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: .codex
        )
        do {
            if let snapshot = try snapshotStore.snapshot(for: identity) {
                return [try reconciledLegacyCodexCredential(snapshot, now: now)]
            }
        } catch {
            return []
        }
        return resolveCodexCandidates(now: now).candidates
    }

    private func reconciledLegacyCodexCredential(
        _ stored: CredentialSnapshot,
        now: Date
    ) throws -> DiscoveredCredential {
        var snapshot = stored
        for candidate in resolveCodexCandidates(now: now).candidates {
            let replacement = CredentialSnapshot(candidate)
            if replacement.isNewerCodexCredential(than: snapshot) {
                snapshot = replacement
            }
        }
        let identity = AccountProviderID(accountID: .legacy, providerID: .codex)
        if snapshot != stored {
            try snapshotStore.save(snapshot, for: identity)
        }
        return snapshot.credential(storage: .accountSnapshot(identity))
    }

    /// The stored Codex credential carries its deadline inside the access
    /// token, and the local store hands back expired tokens for the refresh
    /// path to revive; the snapshot keeps that rule.
    private func codexSnapshotCredential(
        accountID: AccountID,
        now: Date
    ) throws -> DiscoveredCredential {
        try snapshotCredential(
            for: .codex,
            accountID: accountID,
            now: now,
            allowingExpired: true
        )
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
        replacing credential: DiscoveredCredential
    ) throws {
        guard var storage = credential.storage else {
            throw CredentialDiscoveryError.malformed(.codex)
        }
        switch storage {
        case .file, .keychain:
            // Add Account can pin this credential while its OAuth exchange
            // is in flight. The consumed grant now belongs to that pin,
            // not the companion store that login may already have replaced.
            let legacy = AccountProviderID(accountID: .legacy, providerID: .codex)
            if try snapshotStore.snapshot(for: legacy) == CredentialSnapshot(credential) {
                storage = .accountSnapshot(legacy)
            }
        case .accountSnapshot:
            break
        }
        if case let .accountSnapshot(identity) = storage {
            guard
                let stored = try snapshotStore.snapshot(for: identity),
                stored == CredentialSnapshot(credential)
            else {
                throw CredentialDiscoveryError.malformed(.codex)
            }
            try snapshotStore.save(
                stored.rotated(
                    accessToken: accessToken,
                    refreshToken: refreshToken ?? stored.refreshToken,
                    // Codex states the new deadline inside the token itself.
                    expiresAt: codexJWTExpiration(accessToken)
                ),
                for: identity
            )
            return
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
        case .accountSnapshot:
            throw CredentialDiscoveryError.malformed(.codex)
        }
        guard
            var root = try? UsageJSON.object(raw),
            var tokens = UsageJSON.object(root["tokens"]),
            tokens["access_token"] as? String == credential.accessToken,
            (tokens["refresh_token"] as? String)?.nonEmpty == credential.refreshToken,
            (tokens["account_id"] as? String)?.nonEmpty == credential.accountID
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
        case .accountSnapshot:
            throw CredentialDiscoveryError.malformed(.codex)
        }
    }

    func antigravity(
        accountID: AccountID = .legacy,
        now: Date
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            return try snapshotCredential(
                for: .antigravity,
                accountID: accountID,
                now: now
            )
        }
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
        idToken: String? = nil,
        storage: CredentialStorage? = nil
    ) throws {
        if case let .accountSnapshot(identity) = storage {
            try rotateSnapshot(
                identity,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )
            return
        }
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

    var snapshotStore: ProviderCredentialSnapshotStore {
        ProviderCredentialSnapshotStore(keychain: providerKeychain)
    }

    /// A settings-only read. Exact snapshots win and lookup failures never
    /// widen to another account. Do not reconcile or rotate credentials here.
    func maskedIdentity(for identity: AccountProviderID, now: Date) -> String? {
        do {
            if let snapshot = try snapshotStore.snapshot(for: identity) {
                return snapshot.maskedIdentity
            }
            guard identity.accountID == .legacy, identity.providerID == .codex else {
                return nil
            }
            return MaskedAccountIdentity.email(
                try mutableCodexCredential(now: now).email
            )
        } catch {
            return nil
        }
    }

    /// Encodes whichever credential the companion tool holds right now, so
    /// the caller can store it as one account's own secret. Returning the
    /// encoded secret rather than writing it keeps the ownership of the
    /// Keychain item with the registry that knows the account identity.
    func captureCredential(
        for provider: ProviderID,
        now: Date
    ) throws -> String {
        try CredentialSnapshot(
            currentCredential(for: provider, now: now)
        ).encodedSecret()
    }

    /// The one credential a nonlegacy account may use. Any failure here is
    /// terminal on purpose: falling back to local discovery would hand this
    /// account the credential another account already captured.
    func snapshotCredential(
        for provider: ProviderID,
        accountID: AccountID,
        now: Date,
        allowingExpired: Bool = false
    ) throws -> DiscoveredCredential {
        let identity = AccountProviderID(
            accountID: accountID,
            providerID: provider
        )
        guard let snapshot = try snapshotStore.snapshot(for: identity) else {
            throw CredentialDiscoveryError.notFound(provider)
        }
        let credential = snapshot.credential(
            storage: .accountSnapshot(identity)
        )
        if
            !allowingExpired,
            let expiresAt = credential.expiresAt,
            expiresAt <= now
        {
            throw CredentialDiscoveryError.expired(provider)
        }
        return credential
    }

    /// Rewrites one account's snapshot in place. A rotation whose snapshot
    /// has gone missing fails loudly: the old grant is already spent, so
    /// silently dropping the new one would strand the account.
    /// `refreshToken: nil` keeps the stored token; `expiresAt` always
    /// replaces, because an unknown deadline must not read as the old one.
    func rotateSnapshot(
        _ identity: AccountProviderID,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) throws {
        guard let stored = try snapshotStore.snapshot(for: identity) else {
            throw CredentialDiscoveryError.malformed(identity.providerID)
        }
        try snapshotStore.save(
            stored.rotated(
                accessToken: accessToken,
                refreshToken: refreshToken ?? stored.refreshToken,
                expiresAt: expiresAt
            ),
            for: identity
        )
    }

    private func currentCredential(
        for provider: ProviderID,
        now: Date
    ) throws -> DiscoveredCredential {
        switch provider {
        case .claude:
            // Capturing an account whose token is merely stale is normal;
            // the refresh path revives it on the first fetch.
            try claude(now: now, allowingExpired: true)
        case .codex:
            try mutableCodexCredential(now: now)
        case .cursor:
            try cursor(now: now)
        case .antigravity:
            try antigravity(now: now)
        case .copilot:
            try copilot()
        case .devin:
            try devin()
        case .grok:
            try grok(now: now)
        case .kiro:
            try mutableKiroCredential(now: now)
        case .opencode:
            try opencode()
        case .openrouter:
            try openrouter()
        case .zai:
            try zai()
        }
    }

    static func live(
        home: URL = Foundation.FileManager.default
            .homeDirectoryForCurrentUser,
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        keychain: any KeychainReading = SecurityKeychainReader(),
        providerKeychain: any ProviderKeychain = UnifiedProviderKeychain()
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
            providerKeychain: providerKeychain,
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
            root["auth_mode"] == nil
                || root["auth_mode"] as? String == "chatgpt",
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
            storage: storage,
            email: (tokens["id_token"] as? String).flatMap {
                Self.codexIdentityEmail($0)
            } ?? Self.codexIdentityEmail(accessToken)
        )
    }

    private func codexJWTExpiration(_ token: String) -> Date? {
        guard let object = Self.codexJWTPayload(token),
              let expiration = UsageJSON.number(object["exp"])
        else { return nil }
        return Date(timeIntervalSince1970: expiration)
    }

    fileprivate static func codexIdentityEmail(_ token: String) -> String? {
        guard let payload = codexJWTPayload(token) else { return nil }
        return payload["email"] as? String
            ?? (payload["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    private static func codexJWTPayload(_ token: String) -> [String: Any]? {
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
            let object = try? UsageJSON.object(data)
        else {
            return nil
        }
        return object
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

enum MaskedAccountIdentity {
    static func email(_ value: String?) -> String? {
        guard let value, value.count <= 254,
              value.range(
                of: #"^[A-Za-z0-9.!#$%&'*+=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}$"#,
                options: .regularExpression
              ) != nil,
              !value.contains(where: \.isWhitespace)
        else { return nil }
        let parts = value.split(separator: "@")
        guard parts.count == 2, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."),
              !parts[0].contains("..")
        else { return nil }
        let domain = parts[1].split(separator: ".")
        guard domain.allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") })
        else { return nil }
        func mask(_ text: Substring) -> String {
            text.count > 2 ? "\(text.first!)***\(text.last!)" : "***"
        }
        return mask(parts[0]) + "@"
            + domain.dropLast().map(mask).joined(separator: ".")
            + "." + String(domain.last!)
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
