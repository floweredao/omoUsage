import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct AdditionalCredentialDiscoveryTests {
    private let cursorNow = Date(timeIntervalSince1970: 1_786_032_000)

    @Test
    func discoversEveryAdditionalProviderSource() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                [
                    "github.com": ["oauth_token": "copilot-token"]
                ],
                to: home.appending(
                    path: ".config/github-copilot/apps.json"
                )
            )
            try writeText(
                """
                windsurf_api_key = "devin-token"
                api_server_url = "https://server.codeium.com"
                """,
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            try writeJSON(
                ["account": ["key": "grok-token"]],
                to: home.appending(path: ".grok/auth.json")
            )
            try writeJSON(
                ["opencode-go": ["key": "opencode-token"]],
                to: home.appending(
                    path: ".local/share/opencode/auth.json"
                )
            )
            try writeJSON(
                ["apiKey": "openrouter-token"],
                to: home.appending(
                    path: ".config/openusage/openrouter.json"
                )
            )
            try writeJSON(
                ["apiKey": "zai-token"],
                to: home.appending(
                    path: ".config/openusage/zai.json"
                )
            )
            try createCursorDatabase(home)
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.cursor(now: .distantPast).accessToken
                    == "cursor-token"
            )
            #expect(try discovery.copilot().accessToken == "copilot-token")
            #expect(try discovery.devin().accessToken == "devin-token")
            #expect(
                try discovery.grok(now: .distantPast).accessToken
                    == "grok-token"
            )
            #expect(
                try discovery.opencode().accessToken == "opencode-token"
            )
            #expect(
                try discovery.openrouter().accessToken
                    == "openrouter-token"
            )
            #expect(try discovery.zai().accessToken == "zai-token")
        }
    }

    @Test
    func discoversKeychainOnlyCursorAccessAndRefreshTokens() throws {
        try withFixtureDirectory { home in
            let accessToken = cursorJWT(
                subject: "cursor-keychain-subject",
                expiresAt: cursorNow.addingTimeInterval(3_600)
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    values: [
                        "cursor-access-token": accessToken,
                        "cursor-refresh-token":
                            "cursor-keychain-refresh-fixture"
                    ]
                )
            )

            let credential = try discovery.cursor(now: cursorNow)

            #expect(credential.accessToken == accessToken)
            #expect(
                credential.refreshToken
                    == "cursor-keychain-refresh-fixture"
            )
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func prefersCursorDatabaseCredentialOverKeychainCredential() throws {
        try withFixtureDirectory { home in
            let databaseToken = cursorJWT(
                subject: "cursor-database-subject",
                expiresAt: cursorNow.addingTimeInterval(3_600)
            )
            let keychainToken = cursorJWT(
                subject: "cursor-keychain-subject",
                expiresAt: cursorNow.addingTimeInterval(3_600)
            )
            try writeCursorDatabase(
                home,
                values: [
                    "cursorAuth/accessToken": databaseToken,
                    "cursorAuth/refreshToken":
                        "cursor-database-refresh-fixture",
                    "cursorAuth/stripeMembershipType": "pro"
                ]
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    values: [
                        "cursor-access-token": keychainToken,
                        "cursor-refresh-token":
                            "cursor-keychain-refresh-fixture"
                    ]
                )
            )

            let credential = try discovery.cursor(now: cursorNow)

            #expect(credential.accessToken == databaseToken)
            #expect(
                credential.refreshToken
                    == "cursor-database-refresh-fixture"
            )
            #expect(credential.source == .file)
        }
    }

    @Test
    func prefersKeychainWhenFreeDatabaseSubjectDiffers() throws {
        try withFixtureDirectory { home in
            let databaseToken = cursorJWT(
                subject: "cursor-database-subject",
                expiresAt: cursorNow.addingTimeInterval(3_600)
            )
            let keychainToken = cursorJWT(
                subject: "cursor-keychain-subject",
                expiresAt: cursorNow.addingTimeInterval(3_600)
            )
            try writeCursorDatabase(
                home,
                values: [
                    "cursorAuth/accessToken": databaseToken,
                    "cursorAuth/refreshToken":
                        "cursor-database-refresh-fixture",
                    "cursorAuth/stripeMembershipType": "free"
                ]
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    values: [
                        "cursor-access-token": keychainToken,
                        "cursor-refresh-token":
                            "cursor-keychain-refresh-fixture"
                    ]
                )
            )

            let credential = try discovery.cursor(now: cursorNow)

            #expect(credential.accessToken == keychainToken)
            #expect(
                credential.refreshToken
                    == "cursor-keychain-refresh-fixture"
            )
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func rejectsExpiredKeychainCursorAccessToken() throws {
        try withFixtureDirectory { home in
            let expiredToken = cursorJWT(
                subject: "cursor-keychain-subject",
                expiresAt: cursorNow.addingTimeInterval(-60)
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    values: [
                        "cursor-access-token": expiredToken,
                        "cursor-refresh-token":
                            "cursor-keychain-refresh-fixture"
                    ]
                )
            )

            #expect(throws: CredentialDiscoveryError.expired(.cursor)) {
                try discovery.cursor(now: cursorNow)
            }
        }
    }

    @Test
    func discoversGitHubCLIKeychainTokenForConfiguredUser() throws {
        try withFixtureDirectory { home in
            try writeGitHubHosts(
                home,
                user: "octocat-fixture",
                oauthToken: nil
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    accountValues: [
                        "gh:github.com": [
                            "octocat-fixture": goKeyringWrapped(
                                "gh-user-token-fixture"
                            ),
                            "": goKeyringWrapped(
                                "gh-service-token-fixture"
                            )
                        ]
                    ]
                )
            )

            let credential = try discovery.copilot()

            #expect(credential.accessToken == "gh-user-token-fixture")
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func fallsBackToServiceOnlyGitHubCLIKeychainAccount() throws {
        try withFixtureDirectory { home in
            try writeGitHubHosts(home, user: nil, oauthToken: nil)
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    accountValues: [
                        "gh:github.com": [
                            "": goKeyringWrapped(
                                "gh-service-token-fixture"
                            )
                        ]
                    ]
                )
            )

            let credential = try discovery.copilot()

            #expect(
                credential.accessToken == "gh-service-token-fixture"
            )
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func prefersGitHubConfigTokenOverGitHubCLIKeychain() throws {
        try withFixtureDirectory { home in
            try writeGitHubHosts(
                home,
                user: "octocat-fixture",
                oauthToken: "gh-config-token-fixture"
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    accountValues: [
                        "gh:github.com": [
                            "octocat-fixture": goKeyringWrapped(
                                "gh-user-token-fixture"
                            )
                        ]
                    ]
                )
            )

            let credential = try discovery.copilot()

            #expect(
                credential.accessToken == "gh-config-token-fixture"
            )
            #expect(credential.source == .file)
        }
    }

    @Test
    func prefersGitHubCLIKeychainOverCommandFallback() throws {
        try withFixtureDirectory { home in
            try writeGitHubHosts(
                home,
                user: "octocat-fixture",
                oauthToken: nil
            )
            let executable = try writeGitHubCommandFixture(
                home,
                token: "gh-command-token-fixture"
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    accountValues: [
                        "gh:github.com": [
                            "octocat-fixture": goKeyringWrapped(
                                "gh-user-token-fixture"
                            )
                        ]
                    ]
                ),
                commandPaths: [executable]
            )

            let credential = try discovery.copilot()

            #expect(credential.accessToken == "gh-user-token-fixture")
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func ignoresMalformedGoKeyringWrapperWithoutReportingMalformed()
        throws
    {
        try withFixtureDirectory { home in
            try writeGitHubHosts(
                home,
                user: "octocat-fixture",
                oauthToken: nil
            )
            let executable = try writeGitHubCommandFixture(
                home,
                token: "gh-command-token-fixture"
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    accountValues: [
                        "gh:github.com": [
                            "octocat-fixture":
                                "go-keyring-base64:not+valid+base64!!"
                        ]
                    ]
                ),
                commandPaths: [executable]
            )

            let credential = try discovery.copilot()

            #expect(
                credential.accessToken == "gh-command-token-fixture"
            )
            #expect(credential.source == .file)
        }
    }

    @Test
    func ignoresGitHubCLIKeychainFailureWithoutReportingMalformed()
        throws
    {
        try withFixtureDirectory { home in
            try writeGitHubHosts(
                home,
                user: "octocat-fixture",
                oauthToken: nil
            )
            let executable = try writeGitHubCommandFixture(
                home,
                token: "gh-command-token-fixture"
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    failingServices: ["gh:github.com"]
                ),
                commandPaths: [executable]
            )

            let credential = try discovery.copilot()

            #expect(
                credential.accessToken == "gh-command-token-fixture"
            )
            #expect(credential.source == .file)
        }
    }

    @Test
    func reportsMissingProviderWithoutLeakingSecrets() throws {
        try withFixtureDirectory { home in
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )
            #expect(throws: CredentialDiscoveryError.notFound(.copilot)) {
                try discovery.copilot()
            }
            #expect(throws: CredentialDiscoveryError.notFound(.openrouter)) {
                try discovery.openrouter()
            }
        }
    }

    @Test
    func malformedDevinCredentialStoreReportsFailure() throws {
        try withFixtureDirectory { home in
            try writeText(
                "api_server_url = \"https://server.codeium.com\"",
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.devin)) {
                try discovery.devin()
            }
        }
    }

    @Test
    func normalizesQuotedDevinServerURLWithTrailingSlashAndComment()
        throws
    {
        try withFixtureDirectory { home in
            try writeText(
                """
                windsurf_api_key = "devin-token"
                api_server_url = "https://server.codeium.com/"  # primary
                """,
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.devin()

            #expect(credential.accessToken == "devin-token")
            #expect(
                credential.accountID == "https://server.codeium.com"
            )
        }
    }

    @Test
    func prefersDevinTOMLCredentialOverDatabase() throws {
        try withFixtureDirectory { home in
            try writeText(
                """
                windsurf_api_key = "toml-devin-token"
                api_server_url = "https://server.codeium.com"
                """,
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            try writeDevinDatabase(
                home,
                value: #"{"apiKey":"database-devin-token"}"#
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.devin()

            #expect(credential.accessToken == "toml-devin-token")
            #expect(
                credential.accountID == "https://server.codeium.com"
            )
        }
    }

    @Test
    func fallsBackToDevinDatabaseWhenTOMLTokenMissing() throws {
        try withFixtureDirectory { home in
            try writeText(
                "api_server_url = \"https://server.codeium.com\"",
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            try writeDevinDatabase(
                home,
                value: #"{"apiKey":"database-devin-token"}"#
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.devin().accessToken
                    == "database-devin-token"
            )
        }
    }

    @Test
    func discoversDevinDatabaseAuthStatusToken() throws {
        try withFixtureDirectory { home in
            try writeDevinDatabase(
                home,
                value: #"{"apiKey":"database-devin-token"}"#
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.devin()

            #expect(
                credential.accessToken == "database-devin-token"
            )
            #expect(credential.source == .file)
        }
    }

    @Test
    func malformedDevinDatabaseIsNotReportedAsLoggedOut() throws {
        try withFixtureDirectory { home in
            try writeDevinDatabase(home, value: "{not-json")
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.devin)) {
                try discovery.devin()
            }
        }
    }

    @Test(arguments: [
        "http://server.codeium.com",
        "https://evil.example.com"
    ])
    func rejectsUntrustedDevinServerAtProviderBoundary(
        server: String
    ) async throws {
        try await withFixtureDirectoryAsync { home in
            try writeText(
                """
                windsurf_api_key = "devin-token"
                api_server_url = "\(server)"
                """,
                to: home.appending(
                    path: ".local/share/devin/credentials.toml"
                )
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                UnreachableDevinURLProtocol.self
            ]
            UnreachableDevinURLProtocol.reset()
            let provider = DevinUsageProvider(
                discovery: fixtureDiscovery(
                    home: home,
                    keychain: AdditionalKeychain()
                ),
                http: providerHTTPTestClient(
                    session: URLSession(configuration: configuration)
                )
            )

            await #expect(
                throws: ProviderTransportError.invalidResponse(.devin)
            ) {
                _ = try await provider.fetch(
                    now: Date(timeIntervalSince1970: 1_785_675_000)
                )
            }

            #expect(UnreachableDevinURLProtocol.requestCount() == 0)
        }
    }

    @Test
    func malformedGrokCredentialStoreReportsFailure() throws {
        try withFixtureDirectory { home in
            try writeText(
                "{not-json",
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.grok)) {
                try discovery.grok(now: .distantPast)
            }
        }
    }

    @Test
    func skipsExpiredGrokAccountWhenValidAccountExists() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                [
                    "a-expired": [
                        "key": "expired-grok-token",
                        "expires_at": 1
                    ],
                    "b-valid": [
                        "key": "valid-grok-token",
                        "expires_at": 3_000_000_000
                    ]
                ],
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.grok(
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )

            #expect(credential.accountID == "b-valid")
            #expect(credential.accessToken == "valid-grok-token")
        }
    }

    @Test
    func parsesISOExpiresAliasForGrokCredential() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                [
                    "account": [
                        "key": "grok-token",
                        "expires": "2026-09-01T00:00:00Z"
                    ]
                ],
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.grok(
                now: Date(timeIntervalSince1970: 1_785_675_000)
            )

            #expect(
                credential.expiresAt
                    == Date(timeIntervalSince1970: 1_788_220_800)
            )
        }
    }

    @Test
    func prefersExplicitGrokClientIDOverAccountKeySuffix() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                [
                    "account::suffix-client": [
                        "key": "grok-token",
                        "oidc_client_id": "explicit-client"
                    ]
                ],
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.grok(now: .distantPast).oidcClientID
                    == "explicit-client"
            )
        }
    }

    @Test
    func derivesGrokClientIDFromAccountKeySuffix() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                ["account::suffix-client": ["key": "grok-token"]],
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.grok(now: .distantPast).oidcClientID
                    == "suffix-client"
            )
        }
    }

    @Test
    func fallsBackToPinnedGrokClientID() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                ["account": ["key": "grok-token"]],
                to: home.appending(path: ".grok/auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.grok(now: .distantPast).oidcClientID
                    == "b1a00492-073a-47ea-816f-4c329264a828"
            )
        }
    }

    @Test(arguments: OpenCodeKeylessAuthCase.allCases)
    func validKeylessOpenCodeAuthWithoutDatabaseIsNotFound(
        keyless: OpenCodeKeylessAuthCase
    ) throws {
        try withFixtureDirectory { home in
            try writeText(
                keyless.document,
                to: home.appending(
                    path: ".local/share/opencode/auth.json"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.notFound(.opencode)) {
                try discovery.opencode()
            }
        }
    }

    @Test(arguments: OpenCodeKeylessAuthCase.allCases)
    func validKeylessOpenCodeAuthFallsBackToLocalDatabase(
        keyless: OpenCodeKeylessAuthCase
    ) throws {
        try withFixtureDirectory { home in
            let directory = home.appending(
                path: ".local/share/opencode"
            )
            try writeText(
                keyless.document,
                to: directory.appending(path: "auth.json")
            )
            try createOpenCodeDatabase(
                directory.appending(path: "opencode.db")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(try discovery.opencode().accessToken == "local")
        }
    }

    @Test
    func malformedOpenCodeCredentialStoreReportsFailure() throws {
        try withFixtureDirectory { home in
            try writeText(
                "{not-json",
                to: home.appending(
                    path: ".local/share/opencode/auth.json"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.opencode)) {
                try discovery.opencode()
            }
        }
    }

    @Test
    func unreadablePresentOpenCodeCredentialStoreReportsFailure() throws {
        try withFixtureDirectory { home in
            let auth = home.appending(
                path: ".local/share/opencode/auth.json"
            )
            try FileManager.default.createDirectory(
                at: auth,
                withIntermediateDirectories: true
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.opencode)) {
                try discovery.opencode()
            }
        }
    }

    @Test
    func unreadableOpenCodeDataDirectoryReportsFailure() throws {
        try withFixtureDirectory { home in
            try writeText(
                "not-a-directory",
                to: home.appending(path: ".local/share/opencode")
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.malformed(.opencode)) {
                try discovery.opencode()
            }
        }
    }

    @Test
    func discoversCurrentCopilotCLIKeychainToken() throws {
        try withFixtureDirectory { home in
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain(
                    values: ["copilot-cli": "current-copilot-token"]
                )
            )

            let credential = try discovery.copilot()

            #expect(credential.accessToken == "current-copilot-token")
            #expect(credential.source == .keychain)
        }
    }

    @Test
    func prefersOfficialCopilotEnvironmentToken() throws {
        try withFixtureDirectory { home in
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "COPILOT_GITHUB_TOKEN": "environment-copilot-token"
                ],
                keychain: AdditionalKeychain(
                    values: ["copilot-cli": "keychain-copilot-token"]
                )
            )

            let credential = try discovery.copilot()

            #expect(
                credential.accessToken == "environment-copilot-token"
            )
            #expect(credential.source == .environment)
        }
    }

    @Test
    func reportsAPIKeyEnvironmentCredentialSource() throws {
        try withFixtureDirectory { home in
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "OPENROUTER_API_KEY": "environment-openrouter-key"
                ],
                keychain: AdditionalKeychain()
            )

            let credential = try discovery.openrouter()

            #expect(
                credential.accessToken == "environment-openrouter-key"
            )
            #expect(credential.source == .environment)
        }
    }

    @Test
    func discoversDistinctOpenRouterAccountsInKeychain() throws {
        try withFixtureDirectory { home in
            let firstID = AccountID()
            let secondID = AccountID()
            let providerKeychain = AdditionalProviderKeychain()
            let firstStore = try #require(ProviderAPIKeyStore.live(
                for: .openrouter,
                accountID: firstID,
                home: home,
                environment: [:],
                keychain: providerKeychain
            ))
            let secondStore = try #require(ProviderAPIKeyStore.live(
                for: .openrouter,
                accountID: secondID,
                home: home,
                environment: [:],
                keychain: providerKeychain
            ))
            try firstStore.save("first-openrouter-key")
            try secondStore.save("second-openrouter-key")
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: ".claude/credentials.json"),
                    codex: home.appending(path: ".codex/auth.json")
                ),
                environment: [:],
                keychain: AdditionalKeychain(),
                providerKeychain: providerKeychain,
                homeDirectory: home,
                commandPaths: []
            )

            #expect(
                try discovery.openrouter(accountID: firstID).accessToken
                    == "first-openrouter-key"
            )
            #expect(
                try discovery.openrouter(accountID: secondID).accessToken
                    == "second-openrouter-key"
            )
        }
    }

    @Test
    func nonLegacyOpenCodeDoesNotUseCompanionAuthOrDatabase() throws {
        try withFixtureDirectory { home in
            let dataDirectory = home.appending(
                path: ".local/share/opencode",
                directoryHint: .isDirectory
            )
            try writeJSON(
                ["opencode-go": ["key": "legacy-companion-key"]],
                to: dataDirectory.appending(path: "auth.json")
            )
            FileManager.default.createFile(
                atPath: dataDirectory.appending(path: "opencode.db").path,
                contents: Data()
            )
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(throws: CredentialDiscoveryError.notFound(.opencode)) {
                try discovery.opencode(accountID: AccountID())
            }
        }
    }

    @Test
    func copilotKeychainFailureDoesNotSelectBroaderCredential() throws {
        try withFixtureDirectory { home in
            try writeText(
                """
                github.com:
                    oauth_token: broader-github-token
                """,
                to: home.appending(path: ".config/gh/hosts.yml")
            )
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(
                        path: ".claude/credentials.json"
                    ),
                    codex: home.appending(path: ".codex/auth.json")
                ),
                environment: [:],
                keychain: FailingAdditionalKeychain(),
                homeDirectory: home,
                commandPaths: []
            )

            #expect(
                throws: CredentialDiscoveryError.malformed(.copilot)
            ) {
                try discovery.copilot()
            }
        }
    }

    @Test
    func discoversDevinCredentialInXDGDataHome() throws {
        try withFixtureDirectory { home in
            let xdgData = home.appending(path: "custom-data")
            try writeText(
                """
                windsurf_api_key = "xdg-devin-token"
                api_server_url = "https://server.codeium.com"
                """,
                to: xdgData.appending(
                    path: "devin/credentials.toml"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: ["XDG_DATA_HOME": xdgData.path],
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.devin().accessToken == "xdg-devin-token"
            )
        }
    }

    @Test
    func selectsCanonicalOpenCodeDatabaseBeforeFallbackCandidates() throws {
        try withFixtureDirectory { home in
            let directory = home.appending(
                path: ".local/share/opencode",
                directoryHint: .isDirectory
            )
            try createOpenCodeDatabaseFixtures(in: directory)
            let discovery = fixtureDiscovery(
                home: home,
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.openCodeDatabase()?.lastPathComponent
                    == "opencode.db"
            )
            #expect(try discovery.opencode().accessToken == "local")
            try FileManager.default.removeItem(
                at: directory.appending(path: "opencode.db")
            )
            #expect(
                try discovery.openCodeDatabase()?.lastPathComponent
                    == "opencode-backup.db"
            )
            #expect(try discovery.opencode().accessToken == "local")
        }
    }

    @Test
    func usesAbsoluteOpenCodeDataDirectoryDirectlyForAuth() throws {
        try withFixtureDirectory { home in
            let override = home.appending(path: "override-data")
            let xdgData = home.appending(path: "xdg-data")
            try writeOpenCodeAuth(
                token: "override-opencode-token",
                in: override
            )
            try writeOpenCodeAuth(
                token: "nested-opencode-token",
                in: override.appending(path: "opencode")
            )
            try writeOpenCodeAuth(
                token: "xdg-opencode-token",
                in: xdgData.appending(path: "opencode")
            )
            try writeOpenCodeAuth(
                token: "default-opencode-token",
                in: home.appending(path: ".local/share/opencode")
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "OPENCODE_DATA_DIR": override.path,
                    "XDG_DATA_HOME": xdgData.path
                ],
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.opencode().accessToken
                    == "override-opencode-token"
            )
        }
    }

    @Test
    func usesSelectedOpenCodeDirectoryForCanonicalDatabase() throws {
        try withFixtureDirectory { home in
            let override = home.appending(path: "override-data")
            let xdgDirectory = home.appending(path: "xdg-data/opencode")
            let defaultDirectory = home.appending(
                path: ".local/share/opencode"
            )
            try createOpenCodeDatabaseFixtures(in: override)
            try createOpenCodeDatabase(
                override.appending(path: "opencode/opencode.db")
            )
            try createOpenCodeDatabase(
                xdgDirectory.appending(path: "opencode.db")
            )
            try createOpenCodeDatabase(
                defaultDirectory.appending(path: "opencode.db")
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "OPENCODE_DATA_DIR": override.path,
                    "XDG_DATA_HOME": xdgDirectory
                        .deletingLastPathComponent().path
                ],
                keychain: AdditionalKeychain()
            )
            let expected = override.appending(path: "opencode.db")
                .resolvingSymlinksInPath().standardizedFileURL

            #expect(try discovery.openCodeDatabase() == expected)
            #expect(try discovery.opencode().accessToken == "local")
        }
    }

    @Test
    func prefersAbsoluteXDGOpenCodeDirectoryOverDefault() throws {
        try withFixtureDirectory { home in
            let xdgData = home.appending(path: "xdg-data")
            try writeOpenCodeAuth(
                token: "xdg-opencode-token",
                in: xdgData.appending(path: "opencode")
            )
            try writeOpenCodeAuth(
                token: "default-opencode-token",
                in: home.appending(path: ".local/share/opencode")
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: ["XDG_DATA_HOME": xdgData.path],
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.opencode().accessToken
                    == "xdg-opencode-token"
            )
        }
    }

    @Test(arguments: ["relative-data", "", " \t "])
    func ignoresInvalidOpenCodeDataDirectoryOverride(
        override: String
    ) throws {
        try withFixtureDirectory { home in
            let xdgData = home.appending(path: "xdg-data")
            try writeOpenCodeAuth(
                token: "xdg-opencode-token",
                in: xdgData.appending(path: "opencode")
            )
            try writeOpenCodeAuth(
                token: "default-opencode-token",
                in: home.appending(path: ".local/share/opencode")
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "OPENCODE_DATA_DIR": override,
                    "XDG_DATA_HOME": xdgData.path
                ],
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.opencode().accessToken
                    == "xdg-opencode-token"
            )
        }
    }

    @Test
    func ignoresRelativeXDGDataHome() throws {
        try withFixtureDirectory { home in
            try writeJSON(
                [
                    "opencode-go": [
                        "type": "api",
                        "key": "default-opencode-token"
                    ]
                ],
                to: home.appending(
                    path: ".local/share/opencode/auth.json"
                )
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: ["XDG_DATA_HOME": "relative-data"],
                keychain: AdditionalKeychain()
            )

            #expect(
                try discovery.opencode().accessToken
                    == "default-opencode-token"
            )
        }
    }

    enum OpenCodeKeylessAuthCase: String, CaseIterable, Sendable {
        case absentGoLogin
        case emptyGoKey
        case nonObjectGoLogin
        case unrelatedSibling

        var document: String {
            switch self {
            case .absentGoLogin:
                "{}"
            case .emptyGoKey:
                #"{"opencode-go":{"key":""}}"#
            case .nonObjectGoLogin:
                #"{"opencode-go":"signed-out"}"#
            case .unrelatedSibling:
                #"{"other":{"key":"unrelated"}}"#
            }
        }
    }

    private func fixtureDiscovery(
        home: URL,
        environment: [String: String] = [:],
        keychain: AdditionalKeychain,
        commandPaths: [URL] = []
    ) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: ".claude/credentials.json"),
                codex: home.appending(path: ".codex/auth.json")
            ),
            environment: environment,
            keychain: keychain,
            homeDirectory: home,
            commandPaths: commandPaths
        )
    }

    private func writeJSON(
        _ object: [String: Any],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object)
            .write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func writeOpenCodeAuth(
        token: String,
        in directory: URL
    ) throws {
        try writeJSON(
            [
                "opencode-go": [
                    "type": "api",
                    "key": token
                ]
            ],
            to: directory.appending(path: "auth.json")
        )
    }

    private func createOpenCodeDatabaseFixtures(
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let active = directory.appending(path: "opencode.db")
        try createOpenCodeDatabase(active)
        try createOpenCodeDatabase(
            directory.appending(path: "opencode-backup.db")
        )
        try createOpenCodeDatabase(
            directory.appending(path: "opencode-old.db")
        )
        try FileManager.default.copyItem(
            at: active,
            to: directory.appending(path: "opencode-copy.db")
        )
        try FileManager.default.createSymbolicLink(
            atPath: directory.appending(path: "opencode-symlink.db").path,
            withDestinationPath: active.path
        )
        try FileManager.default.linkItem(
            at: active,
            to: directory.appending(path: "opencode-hard-link.db")
        )
    }

    private func createOpenCodeDatabase(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            url.path,
            "CREATE TABLE message(time_created INTEGER, data TEXT);"
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func createCursorDatabase(_ home: URL) throws {
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            """
            CREATE TABLE ItemTable(key TEXT, value TEXT);
            INSERT INTO ItemTable VALUES(
              'cursorAuth/accessToken',
              'cursor-token'
            );
            """
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func writeCursorDatabase(
        _ home: URL,
        values: [String: String]
    ) throws {
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rows = values.keys.sorted().map {
            "INSERT INTO ItemTable VALUES('\($0)', '\(values[$0]!)');"
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            (
                ["CREATE TABLE ItemTable(key TEXT, value TEXT);"] + rows
            ).joined(separator: "\n")
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func cursorJWT(
        subject: String,
        expiresAt: Date
    ) -> String {
        let header = base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = base64URL([
            "sub": subject,
            "exp": Int(expiresAt.timeIntervalSince1970)
        ])
        return "\(header).\(payload).cursor-fixture-signature"
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = (
            try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        ) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func goKeyringWrapped(_ token: String) -> String {
        "go-keyring-base64:"
            + Data(token.utf8).base64EncodedString()
    }

    private func writeGitHubHosts(
        _ home: URL,
        user: String?,
        oauthToken: String?
    ) throws {
        var lines = ["github.com:"]
        if let user {
            lines.append("    user: \(user)")
        }
        if let oauthToken {
            lines.append("    oauth_token: \(oauthToken)")
        }
        try writeText(
            lines.joined(separator: "\n"),
            to: home.appending(path: ".config/gh/hosts.yml")
        )
    }

    private func writeGitHubCommandFixture(
        _ home: URL,
        token: String
    ) throws -> URL {
        let executable = home.appending(path: "bin/gh")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = """
        #!/bin/sh
        printf '%s\\n' '\(token)'
        """
        #expect(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data(script.utf8),
                attributes: [.posixPermissions: 0o755]
            )
        )
        return executable
    }

    private func writeDevinDatabase(
        _ home: URL,
        value: String
    ) throws {
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Devin",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            """
            CREATE TABLE ItemTable(key TEXT, value TEXT);
            INSERT INTO ItemTable VALUES(
              'windsurfAuthStatus',
              '\(value)'
            );
            """
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func withFixtureDirectoryAsync(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "OmoUsageAdditionalAuth-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func withFixtureDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "OmoUsageAdditionalAuth-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class AdditionalProviderKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "|" + account] }
    }
    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "|" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "|" + account) }
    }
}

private final class UnreachableDevinRecorder: @unchecked Sendable {
    static let shared = UnreachableDevinRecorder()

    private let lock = NSLock()
    private var requests = 0

    func reset() {
        lock.withLock { requests = 0 }
    }

    func record() {
        lock.withLock { requests += 1 }
    }

    func count() -> Int {
        lock.withLock { requests }
    }
}

private final class UnreachableDevinURLProtocol: URLProtocol,
    @unchecked Sendable
{
    static func reset() {
        UnreachableDevinRecorder.shared.reset()
    }

    static func requestCount() -> Int {
        UnreachableDevinRecorder.shared.count()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        UnreachableDevinRecorder.shared.record()
        return true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.badServerResponse)
        )
    }

    override func stopLoading() {}
}

private struct AdditionalKeychain: KeychainReading {
    var values: [String: String] = [:]
    var accountValues: [String: [String: String]] = [:]
    var failingServices: Set<String> = []

    func value(service: String, account: String) throws -> String? {
        if failingServices.contains(service) {
            throw KeychainReadError(status: -1)
        }
        if let accounts = accountValues[service] {
            return accounts[account]
        }
        return values[service]
    }
}

private struct FailingAdditionalKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        throw KeychainReadError(status: -1)
    }
}
