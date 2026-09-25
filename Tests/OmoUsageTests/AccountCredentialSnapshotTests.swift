import Foundation
import OmoUsageCore
import Testing
@testable import OmoUsage

@Suite
struct AccountCredentialSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    static let companions: [ProviderID] = [
        .claude,
        .codex,
        .cursor,
        .antigravity,
        .copilot,
        .devin,
        .grok
    ]

    @Test
    func snapshotSecretsUseTheProviderAPIKeyStoreIdentity() throws {
        let accountID = AccountID()
        let identity = AccountProviderID(
            accountID: accountID,
            providerID: .openrouter
        )
        let keyStore = try #require(
            ProviderAPIKeyStore.live(
                for: .openrouter,
                accountID: accountID,
                home: URL(filePath: "/omo-usage-snapshot-tests/home"),
                environment: [:],
                keychain: AccountSnapshotKeychain()
            )
        )
        let store = ProviderCredentialSnapshotStore(
            keychain: AccountSnapshotKeychain()
        )

        #expect(
            ProviderCredentialSnapshotStore.account(for: identity)
                == keyStore.account
        )
        #expect(store.serviceName == keyStore.service)
    }

    @Test(arguments: AccountCredentialSnapshotTests.companions)
    func capturesEachCompanionCredentialAsAnEncodedSnapshot(
        provider: ProviderID
    ) throws {
        try withAccountSnapshotHome { home in
            let discovery = try makeDiscovery(home: home, marker: "captured")

            let secret = try discovery.captureCredential(
                for: provider,
                now: now
            )
            let snapshot = try CredentialSnapshot(
                encodedSecret: secret,
                provider: provider
            )

            #expect(snapshot.version == CredentialSnapshot.currentVersion)
            #expect(snapshot.provider == provider)
            #expect(
                snapshot.accessToken
                    == expectedToken(provider, marker: "captured")
            )
        }
    }

    @Test(arguments: AccountCredentialSnapshotTests.companions)
    func nonlegacyDiscoverySelectsOnlyItsStoredSnapshot(
        provider: ProviderID
    ) throws {
        try withAccountSnapshotHome { home in
            let keychain = AccountSnapshotKeychain()
            let accountID = AccountID()
            let identity = AccountProviderID(
                accountID: accountID,
                providerID: provider
            )
            let captured = try makeDiscovery(
                home: home,
                marker: "captured",
                providerKeychain: keychain
            ).captureCredential(for: provider, now: now)
            try keychain.set(
                captured,
                service: ProviderAPIKeyStore.serviceName,
                account: ProviderCredentialSnapshotStore.account(
                    for: identity
                )
            )
            // The companion tool has since signed into a different login;
            // the captured account must not follow it.
            let discovery = try makeDiscovery(
                home: home,
                marker: "rotated",
                providerKeychain: keychain
            )

            let scoped = try credential(
                from: discovery,
                provider: provider,
                accountID: accountID
            )
            let legacy = try credential(
                from: discovery,
                provider: provider,
                accountID: .legacy
            )

            #expect(
                scoped.accessToken
                    == expectedToken(provider, marker: "captured")
            )
            #expect(
                legacy.accessToken
                    == expectedToken(provider, marker: "rotated")
            )
            #expect(scoped.storage == .accountSnapshot(identity))
        }
    }

    @Test(arguments: AccountCredentialSnapshotTests.companions)
    func nonlegacyDiscoveryNeverFallsBackToLocalCredentials(
        provider: ProviderID
    ) throws {
        try withAccountSnapshotHome { home in
            let discovery = try makeDiscovery(home: home, marker: "local")

            #expect(throws: CredentialDiscoveryError.notFound(provider)) {
                try credential(
                    from: discovery,
                    provider: provider,
                    accountID: AccountID()
                )
            }
            #expect(
                try credential(
                    from: discovery,
                    provider: provider,
                    accountID: .legacy
                ).accessToken == expectedToken(provider, marker: "local")
            )
        }
    }

    @Test
    func legacyCodexPrefersPreservedSnapshotWhileCaptureReadsCompanion() throws {
        try withAccountSnapshotHome { home in
            let keychain = AccountSnapshotKeychain()
            let discoveryA = try makeDiscovery(home: home, marker: "legacy", providerKeychain: keychain)
            let preserved = try discoveryA.captureCredential(for: .codex, now: now)
            try keychain.set(
                preserved,
                service: ProviderAPIKeyStore.serviceName,
                account: ProviderCredentialSnapshotStore.account(for: AccountProviderID(accountID: .legacy, providerID: .codex))
            )
            let discoveryB = try makeDiscovery(home: home, marker: "companion", providerKeychain: keychain)

            #expect(try discoveryB.codex(now: now).accessToken == expectedToken(.codex, marker: "legacy"))
            let captured = try CredentialSnapshot(encodedSecret: discoveryB.captureCredential(for: .codex, now: now), provider: .codex)
            #expect(captured.accessToken == expectedToken(.codex, marker: "companion"))
        }
    }

    @Test
    func malformedLegacyCodexSnapshotFailsClosed() throws {
        let keychain = AccountSnapshotKeychain()
        let identity = AccountProviderID(accountID: .legacy, providerID: .codex)
        try keychain.set("not-a-snapshot", service: ProviderAPIKeyStore.serviceName, account: ProviderCredentialSnapshotStore.account(for: identity))
        let discovery = makeEmptyDiscovery(providerKeychain: keychain)

        #expect(throws: CredentialDiscoveryError.malformed(.codex)) {
            try discovery.codex(now: now)
        }
    }

    @Test
    func snapshotFiledUnderAnotherProviderIsMalformed() throws {
        let keychain = AccountSnapshotKeychain()
        let identity = AccountProviderID(
            accountID: AccountID(),
            providerID: .claude
        )
        try keychain.set(
            CredentialSnapshot(
                provider: .codex,
                accessToken: "snapshot-test-token",
                refreshToken: nil,
                accountReference: nil,
                planName: nil,
                expiresAt: nil,
                source: .file
            ).encodedSecret(),
            service: ProviderAPIKeyStore.serviceName,
            account: ProviderCredentialSnapshotStore.account(for: identity)
        )
        let store = ProviderCredentialSnapshotStore(keychain: keychain)

        #expect(throws: CredentialDiscoveryError.malformed(.claude)) {
            try store.snapshot(for: identity)
        }
    }

    @Test
    func expiredSnapshotIsRejectedWhenNothingCanRefreshIt() throws {
        let keychain = AccountSnapshotKeychain()
        let accountID = AccountID()
        try store(
            CredentialSnapshot(
                provider: .antigravity,
                accessToken: "snapshot-test-antigravity",
                refreshToken: nil,
                accountReference: nil,
                planName: nil,
                expiresAt: now.addingTimeInterval(-1),
                source: .keychain
            ),
            accountID: accountID,
            in: keychain
        )
        let discovery = makeEmptyDiscovery(providerKeychain: keychain)

        #expect(throws: CredentialDiscoveryError.expired(.antigravity)) {
            try discovery.antigravity(accountID: accountID, now: now)
        }
    }

    @Test
    func expiredGrokSnapshotSurvivesWhenARefreshTokenCanReviveIt() throws {
        let keychain = AccountSnapshotKeychain()
        let revivable = AccountID()
        let dead = AccountID()
        try store(
            grokSnapshot(
                accessToken: "snapshot-test-grok-revivable",
                refreshToken: "snapshot-test-grok-refresh",
                expiresAt: now.addingTimeInterval(-1)
            ),
            accountID: revivable,
            in: keychain
        )
        try store(
            grokSnapshot(
                accessToken: "snapshot-test-grok-dead",
                refreshToken: nil,
                expiresAt: now.addingTimeInterval(-1)
            ),
            accountID: dead,
            in: keychain
        )
        let discovery = makeEmptyDiscovery(providerKeychain: keychain)

        #expect(
            try discovery.grok(accountID: revivable, now: now).accessToken
                == "snapshot-test-grok-revivable"
        )
        #expect(throws: CredentialDiscoveryError.expired(.grok)) {
            try discovery.grok(accountID: dead, now: now)
        }
    }

    @Test
    func snapshotDescriptionsNeverCarrySecretMaterial() throws {
        let secret = "snapshot-test-secret-material"
        let snapshot = CredentialSnapshot(
            provider: .claude,
            accessToken: secret,
            refreshToken: secret + "-refresh",
            accountReference: nil,
            planName: "Max 5x",
            expiresAt: now,
            source: .keychain
        )
        let credential = snapshot.credential(
            storage: .accountSnapshot(
                AccountProviderID(
                    accountID: AccountID(),
                    providerID: .claude
                )
            )
        )

        for text in [
            snapshot.description,
            snapshot.debugDescription,
            String(describing: snapshot),
            String(reflecting: snapshot),
            credential.description,
            String(describing: credential)
        ] {
            #expect(!text.contains(secret))
            #expect(text.contains("<redacted>"))
        }
    }

    @Test
    func everyCompanionProviderCarriesItsAccountIdentity() {
        let accountID = AccountID()
        let label = "Second"
        let discovery = makeEmptyDiscovery(
            providerKeychain: AccountSnapshotKeychain()
        )
        let missing = URL(filePath: "/omo-usage-snapshot-tests/missing")
        let providers: [any UsageProvider] = [
            ClaudeUsageProvider(
                accountID: accountID,
                accountLabel: label,
                discovery: discovery,
                desktopUsageURL: missing,
                desktopSessionDiscovery: .unavailable
            ),
            CodexUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            ),
            CursorUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            ),
            AntigravityUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            ),
            CopilotUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            ),
            DevinUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            ),
            GrokUsageProvider(
                discovery: discovery,
                accountID: accountID,
                accountLabel: label
            )
        ]

        #expect(Set(providers.map(\.id)) == Set(Self.companions))
        for provider in providers {
            #expect(provider.accountID == accountID)
            #expect(provider.accountLabel == label)
            #expect(
                provider.accountProviderID
                    == AccountProviderID(
                        accountID: accountID,
                        providerID: provider.id
                    )
            )
        }
    }

    private func grokSnapshot(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?
    ) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .grok,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountReference: "snapshot-test-grok-account",
            planName: nil,
            expiresAt: expiresAt,
            source: .file,
            oidcClientID: CredentialDiscovery.grokDefaultClientID
        )
    }

    private func store(
        _ snapshot: CredentialSnapshot,
        accountID: AccountID,
        in keychain: AccountSnapshotKeychain
    ) throws {
        try ProviderCredentialSnapshotStore(keychain: keychain).save(
            snapshot,
            for: AccountProviderID(
                accountID: accountID,
                providerID: snapshot.provider
            )
        )
    }

    private func credential(
        from discovery: CredentialDiscovery,
        provider: ProviderID,
        accountID: AccountID
    ) throws -> DiscoveredCredential {
        switch provider {
        case .claude:
            try discovery.claude(
                accountID: accountID,
                now: now,
                allowingExpired: true
            )
        case .codex:
            try discovery.codex(accountID: accountID, now: now)
        case .cursor:
            try discovery.cursor(accountID: accountID, now: now)
        case .antigravity:
            try discovery.antigravity(accountID: accountID, now: now)
        case .copilot:
            try discovery.copilot(accountID: accountID)
        case .devin:
            try discovery.devin(accountID: accountID)
        case .grok:
            try discovery.grok(accountID: accountID, now: now)
        default:
            throw CredentialDiscoveryError.notFound(provider)
        }
    }

    private func expectedToken(
        _ provider: ProviderID,
        marker: String
    ) -> String {
        "\(marker)-\(provider.rawValue)-token"
    }

    private func makeEmptyDiscovery(
        providerKeychain: any ProviderKeychain
    ) -> CredentialDiscovery {
        let missing = URL(filePath: "/omo-usage-snapshot-tests/missing")
        return CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: AccountSnapshotReadingKeychain(values: [:]),
            providerKeychain: providerKeychain,
            homeDirectory: missing,
            commandPaths: []
        )
    }

    /// Populates every companion's own credential store under `home` with
    /// tokens stamped by `marker`, so a later read can be told apart from
    /// what an account captured earlier.
    private func makeDiscovery(
        home: URL,
        marker: String,
        providerKeychain: any ProviderKeychain = AccountSnapshotKeychain()
    ) throws -> CredentialDiscovery {
        let claudeURL = home.appending(path: "claude-credentials.json")
        let codexURL = home.appending(path: "codex-auth.json")
        try write(
            """
            {
              "claudeAiOauth": {
                "accessToken": "\(expectedToken(.claude, marker: marker))",
                "refreshToken": "\(marker)-claude-refresh",
                "expiresAt": \(
                    Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
                        * 1_000
                ),
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_5x"
              }
            }
            """,
            to: claudeURL
        )
        try write(
            """
            {
              "auth_mode": "chatgpt",
              "tokens": {
                "access_token": "\(expectedToken(.codex, marker: marker))",
                "refresh_token": "\(marker)-codex-refresh",
                "account_id": "\(marker)-codex-account"
              }
            }
            """,
            to: codexURL
        )
        try write(
            """
            windsurf_api_key = "\(expectedToken(.devin, marker: marker))"
            api_server_url = "https://server.codeium.com"
            """,
            to: home.appending(path: "data/devin/credentials.toml")
        )
        try write(
            """
            {
              "\(marker)-grok-account": {
                "key": "\(expectedToken(.grok, marker: marker))",
                "refresh_token": "\(marker)-grok-refresh",
                "expires_at": "\(
                    now.addingTimeInterval(3_600).ISO8601Format()
                )"
              }
            }
            """,
            to: home.appending(path: "grok/auth.json")
        )
        let antigravity = """
            {
              "access_token": "\(
                expectedToken(.antigravity, marker: marker)
            )",
              "refresh_token": "\(marker)-antigravity-refresh"
            }
            """
        return CredentialDiscovery(
            paths: CredentialPaths(claude: claudeURL, codex: codexURL),
            environment: [
                "COPILOT_GITHUB_TOKEN": expectedToken(
                    .copilot,
                    marker: marker
                ),
                "XDG_DATA_HOME": home.appending(path: "data").path,
                "GROK_HOME": home.appending(path: "grok").path
            ],
            keychain: AccountSnapshotReadingKeychain(
                values: [
                    "cursor-access-token\u{0}": expectedToken(
                        .cursor,
                        marker: marker
                    ),
                    "cursor-refresh-token\u{0}": "\(marker)-cursor-refresh",
                    "gemini\u{0}antigravity": Data(antigravity.utf8)
                        .base64EncodedString()
                ]
            ),
            providerKeychain: providerKeychain,
            homeDirectory: home,
            commandPaths: []
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func withAccountSnapshotHome(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageAccountSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

@Suite(.serialized)
struct AccountCredentialRotationTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func claudeRotationWritesOnlyTheCapturedAccountSecret() async throws {
        try await withAccountRotationHome { home in
            let fixture = try AccountRotationFixture(
                home: home,
                provider: .claude,
                snapshot: CredentialSnapshot(
                    provider: .claude,
                    accessToken: "captured-claude-access",
                    refreshToken: "captured-claude-refresh",
                    accountReference: nil,
                    planName: "Max 5x",
                    expiresAt: now.addingTimeInterval(-60),
                    source: .keychain
                ),
                now: now
            )
            let provider = ClaudeUsageProvider(
                accountID: fixture.accountID,
                accountLabel: "Second",
                discovery: fixture.discovery,
                http: providerHTTPTestClient(
                    session: AccountRotationURLProtocol.session()
                ),
                desktopUsageURL: home.appending(path: "missing-desktop.json"),
                desktopSessionDiscovery: .unavailable,
                refreshCooldown: ClaudeRefreshCooldown(),
                usageCooldown: ClaudeUsageCooldown()
            )

            let usage = try await provider.fetch(now: now)
            let rotated = try #require(
                try fixture.rotatedSnapshot()
            )

            #expect(usage.availability == .available)
            #expect(rotated.accessToken == "rotated-claude-access")
            #expect(rotated.refreshToken == "rotated-claude-refresh")
            // Everything the provider owns survives the rotation.
            #expect(rotated.planName == "Max 5x")
            #expect(
                rotated.expiresAt == now.addingTimeInterval(3_600)
            )
            try fixture.expectOnlyCapturedAccountChanged()
        }
    }

    @Test
    func legacyCodexSnapshotRotatesWithoutTouchingCompanion() async throws {
        try await withAccountRotationHome { home in
            let fixture = try AccountRotationFixture(
                home: home,
                provider: .codex,
                accountID: .legacy,
                snapshot: CredentialSnapshot(
                    provider: .codex,
                    accessToken: "captured-codex-access",
                    refreshToken: "captured-codex-refresh",
                    accountReference: "captured-codex-account",
                    planName: nil,
                    expiresAt: now.addingTimeInterval(-60),
                    source: .file
                ),
                now: now
            )
            let provider = CodexUsageProvider(
                discovery: fixture.discovery,
                http: providerHTTPTestClient(session: AccountRotationURLProtocol.session())
            )

            let usage = try await provider.fetch(now: now)
            let rotated = try #require(try fixture.rotatedSnapshot())
            #expect(usage.availability == .available)
            #expect(rotated.refreshToken == "rotated-codex-refresh")
            try fixture.expectOnlyCapturedAccountChanged()
        }
    }

    @Test
    func codexRotationWritesOnlyTheCapturedAccountSecret() async throws {
        try await withAccountRotationHome { home in
            let fixture = try AccountRotationFixture(
                home: home,
                provider: .codex,
                snapshot: CredentialSnapshot(
                    provider: .codex,
                    accessToken: "captured-codex-access",
                    refreshToken: "captured-codex-refresh",
                    accountReference: "captured-codex-account",
                    planName: nil,
                    expiresAt: now.addingTimeInterval(-60),
                    source: .file
                ),
                now: now
            )
            let provider = CodexUsageProvider(
                discovery: fixture.discovery,
                http: providerHTTPTestClient(
                    session: AccountRotationURLProtocol.session()
                ),
                accountID: fixture.accountID,
                accountLabel: "Second"
            )

            let usage = try await provider.fetch(now: now)
            let rotated = try #require(
                try fixture.rotatedSnapshot()
            )

            #expect(usage.availability == .available)
            #expect(
                rotated.accessToken
                    == AccountRotationURLProtocol.rotatedCodexAccessToken
            )
            #expect(rotated.refreshToken == "rotated-codex-refresh")
            #expect(rotated.accountReference == "captured-codex-account")
            // Codex states the new deadline inside the token itself.
            #expect(rotated.expiresAt == now.addingTimeInterval(3_600))
            try fixture.expectOnlyCapturedAccountChanged()
        }
    }

    @Test
    func grokRotationWritesOnlyTheCapturedAccountSecret() async throws {
        try await withAccountRotationHome { home in
            let fixture = try AccountRotationFixture(
                home: home,
                provider: .grok,
                snapshot: CredentialSnapshot(
                    provider: .grok,
                    accessToken: "captured-grok-access",
                    refreshToken: "captured-grok-refresh",
                    accountReference: "captured-grok-account",
                    planName: nil,
                    expiresAt: now.addingTimeInterval(-60),
                    source: .file,
                    oidcClientID: CredentialDiscovery.grokDefaultClientID
                ),
                now: now
            )
            let provider = GrokUsageProvider(
                discovery: fixture.discovery,
                http: providerHTTPTestClient(
                    session: AccountRotationURLProtocol.session()
                ),
                accountID: fixture.accountID,
                accountLabel: "Second"
            )

            let usage = try await provider.fetch(now: now)
            let rotated = try #require(
                try fixture.rotatedSnapshot()
            )

            #expect(usage.availability == .available)
            #expect(rotated.accessToken == "rotated-grok-access")
            #expect(rotated.refreshToken == "rotated-grok-refresh")
            #expect(rotated.accountReference == "captured-grok-account")
            #expect(
                rotated.oidcClientID
                    == CredentialDiscovery.grokDefaultClientID
            )
            try fixture.expectOnlyCapturedAccountChanged()
        }
    }

    private func withAccountRotationHome(
        _ body: (URL) async throws -> Void
    ) async throws {
        AccountRotationURLProtocol.reset()
        URLProtocol.registerClass(AccountRotationURLProtocol.self)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageAccountRotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            URLProtocol.unregisterClass(AccountRotationURLProtocol.self)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(directory)
    }
}

/// One captured account under rotation, plus the untouched neighbours a
/// rotation must never reach: a second account's secret and whatever the
/// companion tool keeps in its own store.
private struct AccountRotationFixture {
    let accountID = AccountID()
    let controlAccountID = AccountID()
    let discovery: CredentialDiscovery
    let keychain: AccountSnapshotKeychain
    let identity: AccountProviderID
    let controlIdentity: AccountProviderID
    let controlSecret: String
    let localCredentialURL: URL
    let localCredentialData: Data

    init(
        home: URL,
        provider: ProviderID,
        accountID: AccountID? = nil,
        snapshot: CredentialSnapshot,
        now: Date
    ) throws {
        keychain = AccountSnapshotKeychain()
        let selectedAccountID = accountID ?? self.accountID
        identity = AccountProviderID(
            accountID: selectedAccountID,
            providerID: provider
        )
        controlIdentity = AccountProviderID(
            accountID: controlAccountID,
            providerID: provider
        )
        let store = ProviderCredentialSnapshotStore(keychain: keychain)
        try store.save(snapshot, for: identity)
        let control = snapshot.rotated(
            accessToken: "control-\(provider.rawValue)-access",
            refreshToken: "control-\(provider.rawValue)-refresh",
            expiresAt: now.addingTimeInterval(-60)
        )
        try store.save(control, for: controlIdentity)
        controlSecret = try control.encodedSecret()

        let claudeURL = home.appending(path: "claude-credentials.json")
        let codexURL = home.appending(path: "codex-auth.json")
        let grokURL = home.appending(path: "grok/auth.json")
        try AccountRotationFixture.write(
            """
            {
              "claudeAiOauth": {
                "accessToken": "local-claude-access",
                "refreshToken": "local-claude-refresh",
                "expiresAt": \(
                    Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
                        * 1_000
                ),
                "subscriptionType": "pro"
              }
            }
            """,
            to: claudeURL
        )
        try AccountRotationFixture.write(
            """
            {
              "auth_mode": "chatgpt",
              "tokens": {
                "access_token": "local-codex-access",
                "refresh_token": "local-codex-refresh",
                "account_id": "local-codex-account"
              }
            }
            """,
            to: codexURL
        )
        try AccountRotationFixture.write(
            """
            {
              "local-grok-account": {
                "key": "local-grok-access",
                "refresh_token": "local-grok-refresh"
              }
            }
            """,
            to: grokURL
        )
        localCredentialURL = switch provider {
        case .claude: claudeURL
        case .codex: codexURL
        default: grokURL
        }
        localCredentialData = try Data(contentsOf: localCredentialURL)
        discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: claudeURL, codex: codexURL),
            environment: ["GROK_HOME": home.appending(path: "grok").path],
            keychain: AccountSnapshotReadingKeychain(values: [:]),
            providerKeychain: keychain,
            keychainWriter: AccountRotationRefusingWriter(),
            homeDirectory: home,
            commandPaths: []
        )
        keychain.clearWrittenAccounts()
    }

    func rotatedSnapshot() throws -> CredentialSnapshot? {
        try ProviderCredentialSnapshotStore(keychain: keychain)
            .snapshot(for: identity)
    }

    func expectOnlyCapturedAccountChanged() throws {
        #expect(
            keychain.writtenAccounts() == [
                ProviderCredentialSnapshotStore.account(for: identity)
            ]
        )
        #expect(
            keychain.storedValue(
                account: ProviderCredentialSnapshotStore.account(
                    for: controlIdentity
                )
            ) == controlSecret
        )
        #expect(
            try Data(contentsOf: localCredentialURL) == localCredentialData
        )
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

/// Writable in-memory stand-in for the app's own Keychain items.
private final class AccountSnapshotKeychain: ProviderKeychain,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writes: [String] = []

    func value(service: String, account: String) throws -> String? {
        lock.withLock { values["\(service)\u{0}\(account)"] }
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.withLock {
            values["\(service)\u{0}\(account)"] = value
            writes.append(account)
        }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock {
            values.removeValue(forKey: "\(service)\u{0}\(account)")
        }
    }

    func storedValue(
        service: String = ProviderAPIKeyStore.serviceName,
        account: String
    ) -> String? {
        lock.withLock { values["\(service)\u{0}\(account)"] }
    }

    /// Records writes rather than counting them, so a rotation that lands
    /// on a second account fails the test by name.
    func writtenAccounts() -> [String] {
        lock.withLock { writes }
    }

    func clearWrittenAccounts() {
        lock.withLock { writes.removeAll() }
    }
}

private struct AccountSnapshotReadingKeychain: KeychainReading {
    let values: [String: String]

    func value(service: String, account: String) throws -> String? {
        values["\(service)\u{0}\(account)"]
    }
}

/// A snapshot rotation must never reach the companion tool's Keychain item.
private struct AccountRotationRefusingWriter: KeychainWriting {
    struct UnexpectedWrite: Error {}

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        throw UnexpectedWrite()
    }
}

private final class AccountRotationURLProtocol: URLProtocol,
    @unchecked Sendable
{
    static let rotatedCodexAccessToken = AccountRotationURLProtocol.jwt(
        expiresAt: Date(timeIntervalSince1970: 1_785_675_000 + 3_600)
    )

    private static let lock = NSLock()
    private nonisolated(unsafe) static var unauthorizedRequests = 0

    static func reset() {
        lock.withLock { unauthorizedRequests = 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountRotationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func jwt(expiresAt: Date) -> String {
        let payload = Data(
            "{\"exp\":\(Int(expiresAt.timeIntervalSince1970))}".utf8
        )
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        switch url {
        case "https://platform.claude.com/v1/oauth/token":
            respond(200, """
                {
                  "access_token": "rotated-claude-access",
                  "refresh_token": "rotated-claude-refresh",
                  "expires_in": 3600
                }
                """)
        case "https://api.anthropic.com/api/oauth/usage"
            + "?cedar_ember=1&skip_spend=1":
            authorized(bearer, "Bearer rotated-claude-access", """
                {
                  "five_hour": {"utilization": 42},
                  "seven_day": {"utilization": 25}
                }
                """)
        case "https://auth.openai.com/oauth/token":
            respond(200, """
                {
                  "access_token": "\(Self.rotatedCodexAccessToken)",
                  "refresh_token": "rotated-codex-refresh"
                }
                """)
        case "https://chatgpt.com/backend-api/wham/usage":
            authorized(
                bearer,
                "Bearer \(Self.rotatedCodexAccessToken)",
                """
                {
                  "plan_type": "plus",
                  "rate_limit": {
                    "secondary_window": {
                      "used_percent": 12,
                      "limit_window_seconds": 604800,
                      "reset_at": 1786100400
                    }
                  }
                }
                """
            )
        case "https://auth.x.ai/oauth2/token":
            respond(200, """
                {
                  "access_token": "rotated-grok-access",
                  "refresh_token": "rotated-grok-refresh",
                  "expires_in": 3600
                }
                """)
        case "https://cli-chat-proxy.grok.com/v1/billing?format=credits":
            authorized(bearer, "Bearer rotated-grok-access", """
                {"config": {"creditUsagePercent": 40}}
                """)
        case "https://cli-chat-proxy.grok.com/v1/settings":
            authorized(bearer, "Bearer rotated-grok-access", """
                {"subscription_tier_display": "Grok Pro"}
                """)
        default:
            respond(404, "{}")
        }
    }

    override func stopLoading() {}

    /// The usage read only answers the rotated token, so a fetch that used
    /// any other account's credential cannot reach `.available`.
    private func authorized(
        _ bearer: String?,
        _ expected: String,
        _ body: String
    ) {
        guard bearer == expected else {
            Self.lock.withLock { Self.unauthorizedRequests += 1 }
            respond(401, #"{"error":"unauthorized"}"#)
            return
        }
        respond(200, body)
    }

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
