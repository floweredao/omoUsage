import Foundation
import Testing
@testable import OmoUsage

@Suite
struct CredentialDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func discoversClaudeAndCodexFiles() throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(path: "claude.json")
            let codexURL = directory.appending(path: "codex.json")
            try Data(
                """
                {
                  "claudeAiOauth": {
                    "accessToken": "fixture-claude-access",
                    "refreshToken": "fixture-claude-refresh",
                    "expiresAt": 1785685000000,
                    "subscriptionType": "pro"
                  }
                }
                """.utf8
            ).write(to: claudeURL)
            try Data(
                """
                {
                  "auth_mode": "chatgpt",
                  "tokens": {
                    "access_token": "fixture-codex-access",
                    "refresh_token": "fixture-codex-refresh",
                    "account_id": "fixture-account"
                  }
                }
                """.utf8
            ).write(to: codexURL)
            let discovery = makeDiscovery(
                claude: claudeURL,
                codex: codexURL
            )

            let claude = try discovery.claude(now: now)
            let codex = try discovery.codex(now: now)

            #expect(claude.source == .file)
            #expect(claude.planName == "Pro")
            #expect(codex.source == .file)
            #expect(codex.accountID == "fixture-account")
        }
    }

    @Test
    func discoversBase64AntigravityKeychainToken() throws {
        let payload = Data(
            """
            {
              "access_token": "fixture-antigravity-access",
              "refresh_token": "fixture-antigravity-refresh",
              "expiry": 1785685000
            }
            """.utf8
        ).base64EncodedString()
        let keychain = StubKeychain(
            values: ["gemini\u{0}antigravity": payload]
        )
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: keychain
        )

        let credential = try discovery.antigravity(now: now)

        #expect(credential.source == .keychain)
        #expect(credential.expiresAt?.timeIntervalSince1970 == 1_785_685_000)
    }

    @Test
    func liveDiscoveryDefaultsToSecurityKeychainReader() throws {
        try withFixtureDirectory { directory in
            let discovery = CredentialDiscovery.live(
                home: directory,
                environment: [:]
            )

            #expect(discovery.keychain is SecurityKeychainReader)
            #expect(
                discovery.paths.claude
                    == directory.appending(
                        components: ".claude",
                        ".credentials.json"
                    )
            )
        }
    }

    @Test
    func discoversClaudeCredentialsInConfigDirectory() throws {
        try withFixtureDirectory { directory in
            let configDirectory = directory.appending(
                path: "claude-config"
            )
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true
            )
            try Data(
                claudeCredentialsJSON(
                    accessToken: "fixture-config-access",
                    expiresAtMilliseconds: 1_785_685_000_000
                ).utf8
            ).write(
                to: configDirectory.appending(
                    path: ".credentials.json"
                )
            )
            let discovery = CredentialDiscovery.live(
                home: directory,
                environment: [
                    "CLAUDE_CONFIG_DIR": configDirectory.path
                ],
                keychain: StubKeychain(values: [:])
            )

            let credential = try discovery.claude(now: now)

            #expect(credential.accessToken == "fixture-config-access")
            #expect(credential.source == .file)
        }
    }

    @Test(arguments: [
        "Claude Code-local-oauth-credentials",
        "Claude Code-staging-oauth-credentials",
        "Claude Code-custom-oauth-credentials"
    ])
    func discoversAlternateClaudeKeychainService(
        service: String
    ) throws {
        let discovery = claudeKeychainDiscovery(
            values: [
                "\(service)\u{0}": claudeCredentialsJSON(
                    accessToken: "fixture-alternate-access",
                    expiresAtMilliseconds: 1_785_685_000_000
                )
            ]
        )

        let credential = try discovery.claude(now: now)

        #expect(credential.accessToken == "fixture-alternate-access")
        #expect(credential.source == .keychain)
    }

    @Test
    func prefersStoredKeychainCredentialOverEnvironmentToken() throws {
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [
                "CLAUDE_CODE_OAUTH_TOKEN": "fixture-environment-access"
            ],
            keychain: StubKeychain(
                values: [
                    "Claude Code-credentials\u{0}":
                        claudeCredentialsJSON(
                            accessToken: "fixture-keychain-access",
                            expiresAtMilliseconds: 1_785_685_000_000
                        )
                ]
            )
        )

        let credential = try discovery.claude(now: now)

        #expect(credential.accessToken == "fixture-keychain-access")
        #expect(credential.source == .keychain)
        #expect(
            !credential.description.contains("fixture-keychain-access")
        )
    }

    @Test(arguments: [
        """
        {
          "claudeAiOauth": {
            "accessToken": "fixture-unusable-access",
            "expiresAt": 1000
          }
        }
        """,
        "{broken"
    ])
    func fallsBackToValidFileWhenKeychainCandidateUnusable(
        stored: String
    ) throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(path: "claude.json")
            try Data(
                claudeCredentialsJSON(
                    accessToken: "fixture-file-access",
                    expiresAtMilliseconds: 1_785_685_000_000
                ).utf8
            ).write(to: claudeURL)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: directory.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: StubKeychain(
                    values: ["Claude Code-credentials\u{0}": stored]
                )
            )

            let credential = try discovery.claude(now: now)

            #expect(credential.accessToken == "fixture-file-access")
            #expect(credential.source == .file)
        }
    }

    @Test
    func prefersKeychainCredentialOverFileCredential() throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(path: "claude.json")
            try Data(
                claudeCredentialsJSON(
                    accessToken: "fixture-file-access",
                    expiresAtMilliseconds: 1_785_685_000_000
                ).utf8
            ).write(to: claudeURL)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: directory.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: StubKeychain(
                    values: [
                        "Claude Code-credentials\u{0}":
                            claudeCredentialsJSON(
                                accessToken: "fixture-keychain-access",
                                expiresAtMilliseconds: 1_785_685_000_000
                            )
                    ]
                )
            )

            let credential = try discovery.claude(now: now)

            #expect(
                credential.accessToken == "fixture-keychain-access"
            )
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func attachesExactKeychainStorageLocation() throws {
        let discovery = claudeKeychainDiscovery(
            values: [
                "Claude Code-staging-oauth-credentials\u{0}":
                    claudeCredentialsJSON(
                        accessToken: "fixture-staging-access",
                        expiresAtMilliseconds: 1_785_685_000_000
                    )
            ]
        )

        let credential = try discovery.claude(now: now)

        #expect(
            credential.storage
                == .keychain(
                    service: "Claude Code-staging-oauth-credentials",
                    account: ""
                )
        )
    }

    @Test
    func attachesExactFileStorageLocation() throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(path: "claude.json")
            try Data(
                claudeCredentialsJSON(
                    accessToken: "fixture-file-access",
                    expiresAtMilliseconds: 1_785_685_000_000
                ).utf8
            ).write(to: claudeURL)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: directory.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: StubKeychain(values: [:])
            )

            let credential = try discovery.claude(now: now)

            #expect(credential.storage == .file(claudeURL))
        }
    }

    @Test
    func persistsRotatedCredentialToOriginatingKeychainService() throws {
        let writer = RecordingKeychainWriter()
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: StubKeychain(
                values: [
                    "Claude Code-staging-oauth-credentials\u{0}":
                        claudeCredentialsJSON(
                            accessToken: "fixture-staging-access",
                            expiresAtMilliseconds: 1_785_685_000_000
                        )
                ]
            ),
            keychainWriter: writer
        )
        let credential = try discovery.claude(now: now)

        try discovery.persistClaudeCredential(
            accessToken: "fixture-rotated-access",
            refreshToken: "fixture-rotated-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_785_695_000),
            source: credential.source,
            storage: credential.storage
        )

        #expect(
            writer.records.map(\.service)
                == ["Claude Code-staging-oauth-credentials"]
        )
        let stored = try #require(writer.records.first?.value)
        #expect(stored.contains("fixture-rotated-access"))
        #expect(stored.contains("\"subscriptionType\":\"pro\""))
    }

    @Test
    func persistsRotatedCredentialToOriginatingFileURL() throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(
                path: "custom-credentials.json"
            )
            let base = directory.appending(path: "base.json")
            try Data(
                """
                {
                  "claudeAiOauth": {
                    "accessToken": "fixture-file-access",
                    "refreshToken": "fixture-claude-refresh",
                    "expiresAt": 1785685000000,
                    "subscriptionType": "pro",
                    "scopes": ["user:inference"]
                  }
                }
                """.utf8
            ).write(to: claudeURL)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: directory.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: StubKeychain(values: [:])
            )
            let credential = try discovery.claude(now: now)

            try discovery.persistClaudeCredential(
                accessToken: "fixture-rotated-access",
                refreshToken: "fixture-rotated-refresh",
                expiresAt: Date(timeIntervalSince1970: 1_785_695_000),
                source: credential.source,
                storage: credential.storage
            )

            let written = try #require(
                try? UsageJSON.object(Data(contentsOf: claudeURL))
            )
            let oauth = try #require(
                UsageJSON.object(written["claudeAiOauth"])
            )
            #expect(
                oauth["accessToken"] as? String
                    == "fixture-rotated-access"
            )
            #expect(oauth["subscriptionType"] as? String == "pro")
            #expect(oauth["scopes"] as? [String] == ["user:inference"])
            #expect(
                !FileManager.default.fileExists(atPath: base.path)
            )
        }
    }

    @Test
    func reportsMostActionableClaudeCandidateFailure() throws {
        try withFixtureDirectory { directory in
            let claudeURL = directory.appending(path: "claude.json")
            try Data("{broken".utf8).write(to: claudeURL)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: directory.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: StubKeychain(
                    values: [
                        "Claude Code-credentials\u{0}":
                            claudeCredentialsJSON(
                                accessToken: "fixture-expired-access",
                                expiresAtMilliseconds: 1_000
                            )
                    ]
                )
            )

            #expect(throws: CredentialDiscoveryError.expired(.claude)) {
                try discovery.claude(now: now)
            }
        }
    }

    @Test
    func usesEnvironmentTokenWhenNoStoredCandidateParses() throws {
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [
                "CLAUDE_CODE_OAUTH_TOKEN": "fixture-environment-access"
            ],
            keychain: StubKeychain(
                values: ["Claude Code-credentials\u{0}": "{broken"]
            )
        )

        let credential = try discovery.claude(now: now)

        #expect(
            credential.accessToken == "fixture-environment-access"
        )
        #expect(credential.source == .environment)
        #expect(credential.storage == nil)
    }

    @Test
    func keepsStorageLocationOutOfCredentialDescription() throws {
        let discovery = claudeKeychainDiscovery(
            values: [
                "Claude Code-custom-oauth-credentials\u{0}":
                    claudeCredentialsJSON(
                        accessToken: "fixture-custom-access",
                        expiresAtMilliseconds: 1_785_685_000_000
                    )
            ]
        )

        let description = try discovery.claude(now: now).description

        #expect(!description.contains("fixture-custom-access"))
        #expect(
            !description.contains(
                "Claude Code-custom-oauth-credentials"
            )
        )
        #expect(!description.contains("oauth-credentials"))
        #expect(description.contains("<redacted>"))
    }

    @Test
    func acceptsFutureISO8601AntigravityExpiry() throws {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "refresh_token": "fixture-antigravity-refresh",
              "expiry": "2026-09-01T00:00:00Z"
            }
            """
        )

        let credential = try discovery.antigravity(now: now)

        #expect(credential.source == .keychain)
        #expect(
            credential.expiresAt
                == Date(timeIntervalSince1970: 1_788_220_800)
        )
    }

    @Test
    func rejectsExpiredISO8601AntigravityExpiresAtAlias() {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "expires_at": "2026-01-01T00:00:00Z"
            }
            """
        )

        #expect(
            throws: CredentialDiscoveryError.expired(.antigravity)
        ) {
            try discovery.antigravity(now: now)
        }
    }

    @Test
    func rejectsExpiredISO8601AntigravityExpiryDateAlias() {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "expiry_date": "2026-01-01T00:00:00Z"
            }
            """
        )

        #expect(
            throws: CredentialDiscoveryError.expired(.antigravity)
        ) {
            try discovery.antigravity(now: now)
        }
    }

    @Test
    func acceptsFractionalISO8601AntigravityExpiry() throws {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "expiry": "2026-09-01T00:00:00.500Z"
            }
            """
        )

        let credential = try discovery.antigravity(now: now)

        #expect(
            credential.expiresAt
                == Date(timeIntervalSince1970: 1_788_220_800.5)
        )
    }

    @Test
    func acceptsNumericMillisecondAntigravityExpiry() throws {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "expiry": 1785685000000
            }
            """
        )

        let credential = try discovery.antigravity(now: now)

        #expect(
            credential.expiresAt
                == Date(timeIntervalSince1970: 1_785_685_000)
        )
    }

    @Test
    func treatsUnparsableAntigravityExpiryAsUnknown() throws {
        let discovery = antigravityDiscovery(
            """
            {
              "access_token": "fixture-antigravity-access",
              "expiry": "not-a-timestamp"
            }
            """
        )

        let credential = try discovery.antigravity(now: now)

        #expect(credential.expiresAt == nil)
        #expect(
            credential.accessToken == "fixture-antigravity-access"
        )
    }

    @Test
    func distinguishesMissingMalformedAndExpired() throws {
        try withFixtureDirectory { directory in
            let missing = directory.appending(path: "missing.json")
            let malformed = directory.appending(path: "malformed.json")
            let expired = directory.appending(path: "expired.json")
            try Data("{broken".utf8).write(to: malformed)
            try Data(
                """
                {
                  "claudeAiOauth": {
                    "accessToken": "fixture-expired-secret",
                    "expiresAt": 1000
                  }
                }
                """.utf8
            ).write(to: expired)

            #expect(throws: CredentialDiscoveryError.notFound(.claude)) {
                _ = try makeDiscovery(claude: missing, codex: missing).claude(now: now)
            }
            #expect(throws: CredentialDiscoveryError.malformed(.codex)) {
                _ = try makeDiscovery(claude: missing, codex: malformed).codex(now: now)
            }
            #expect(throws: CredentialDiscoveryError.expired(.claude)) {
                _ = try makeDiscovery(claude: expired, codex: missing).claude(now: now)
            }
        }
    }

    @Test
    func discoversDetailedClaudePlanVariants() throws {
        try withFixtureDirectory { directory in
            let claude = directory.appending(path: "claude.json")
            let missing = directory.appending(path: "missing.json")
            let discovery = makeDiscovery(
                claude: claude,
                codex: missing
            )

            func planName(
                subscription: String,
                tier: String
            ) throws -> String? {
                try Data(
                    """
                    {
                      "claudeAiOauth": {
                        "accessToken": "oauth-test",
                        "subscriptionType": "\(subscription)",
                        "rateLimitTier": "\(tier)",
                        "expiresAt": 4102444800000
                      }
                    }
                    """.utf8
                ).write(to: claude)
                return try discovery.claude(
                    now: Date(timeIntervalSince1970: 1_785_675_000)
                ).planName
            }

            let max5x = try planName(
                subscription: "max",
                tier: "default_claude_max_5x"
            )
            let max20x = try planName(
                subscription: "max",
                tier: "default_claude_max_20x"
            )
            let max = try planName(
                subscription: "max",
                tier: "default_claude_max"
            )
            let plus = try planName(
                subscription: "plus",
                tier: "default_claude_plus"
            )

            #expect(max5x == "Max 5x")
            #expect(max20x == "Max 20x")
            #expect(max == "Max")
            #expect(plus == "Plus")
        }
    }

    @Test
    func redactsEverySecretFromDiagnostics() {
        let diagnostic = SecretRedactor.redact(
            "access=fixture-access refresh=fixture-refresh",
            secrets: ["fixture-access", "fixture-refresh"]
        )

        #expect(!diagnostic.contains("fixture-access"))
        #expect(!diagnostic.contains("fixture-refresh"))
        #expect(diagnostic.contains("<redacted>"))
    }

    private func claudeCredentialsJSON(
        accessToken: String,
        expiresAtMilliseconds: Int
    ) -> String {
        """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "refreshToken": "fixture-claude-refresh",
            "expiresAt": \(expiresAtMilliseconds),
            "subscriptionType": "pro"
          }
        }
        """
    }

    private func claudeKeychainDiscovery(
        values: [String: String]
    ) -> CredentialDiscovery {
        let missing = URL(filePath: "/definitely/missing")
        return CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: StubKeychain(values: values)
        )
    }

    private func antigravityDiscovery(
        _ json: String
    ) -> CredentialDiscovery {
        let missing = URL(filePath: "/definitely/missing")
        return CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: StubKeychain(
                values: [
                    "gemini\u{0}antigravity":
                        Data(json.utf8).base64EncodedString()
                ]
            )
        )
    }

    private func makeDiscovery(
        claude: URL,
        codex: URL
    ) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(claude: claude, codex: codex),
            environment: [:],
            keychain: StubKeychain(values: [:])
        )
    }

    private func withFixtureDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageCredentialTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class RecordingKeychainWriter: KeychainWriting,
    @unchecked Sendable
{
    struct Record: Equatable {
        let value: String
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var stored: [Record] = []

    var records: [Record] {
        lock.withLock { stored }
    }

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        lock.withLock {
            stored.append(
                Record(
                    value: value,
                    service: service,
                    account: account
                )
            )
        }
    }
}

private struct StubKeychain: KeychainReading {
    let values: [String: String]

    func value(service: String, account: String) throws -> String? {
        values["\(service)\u{0}\(account)"]
    }
}
