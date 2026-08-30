import Foundation
import Testing
@testable import OmoUsage

@Suite
struct AdditionalCredentialDiscoveryTests {
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
    func ignoresNonstandardOpenCodeDataDirectoryOverride() throws {
        try withFixtureDirectory { home in
            let xdgData = home.appending(path: "xdg-data")
            try writeJSON(
                [
                    "opencode-go": [
                        "type": "api",
                        "key": "xdg-opencode-token"
                    ]
                ],
                to: xdgData.appending(path: "opencode/auth.json")
            )
            let unrelated = home.appending(path: "unrelated-opencode")
            try writeJSON(
                [
                    "opencode-go": [
                        "type": "api",
                        "key": "wrong-token"
                    ]
                ],
                to: unrelated.appending(path: "auth.json")
            )
            let discovery = fixtureDiscovery(
                home: home,
                environment: [
                    "XDG_DATA_HOME": xdgData.path,
                    "OPENCODE_DATA_DIR": unrelated.path
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

    private func fixtureDiscovery(
        home: URL,
        environment: [String: String] = [:],
        keychain: AdditionalKeychain
    ) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: ".claude/credentials.json"),
                codex: home.appending(path: ".codex/auth.json")
            ),
            environment: environment,
            keychain: keychain,
            homeDirectory: home,
            commandPaths: []
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

private struct AdditionalKeychain: KeychainReading {
    var values: [String: String] = [:]

    func value(service: String, account: String) throws -> String? {
        values[service]
    }
}

private struct FailingAdditionalKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        throw KeychainReadError(status: -1)
    }
}
