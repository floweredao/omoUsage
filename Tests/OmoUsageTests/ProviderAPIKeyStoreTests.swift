import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct ProviderAPIKeyStoreTests {
    @Test
    func savesSecretsWithoutCreatingAPlaintextFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "provider.json")
        let store = ProviderAPIKeyStore(
            configURL: configURL,
            environment: [:],
            environmentNames: []
        )

        try store.save("secret")

        #expect(store.load() == "secret")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test
    func explicitEnvironmentKeyOverridesSavedKey() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyPriority-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "provider.json")
        let stored = ProviderAPIKeyStore(
            configURL: configURL,
            environment: [:],
            environmentNames: []
        )
        try stored.save("saved-key")
        let resolved = ProviderAPIKeyStore(
            configURL: configURL,
            environment: ["OPENROUTER_API_KEY": "environment-key"],
            environmentNames: ["OPENROUTER_API_KEY"]
        )

        #expect(resolved.load() == "environment-key")
    }

    @Test
    func stableServiceAndProviderQualifiedAccountsCoverEveryManagedProvider() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyNaming-\(UUID().uuidString)"
        )
        let keychain = APIKeyStoreFakeKeychain()
        for provider in [ProviderID.opencode, .openrouter, .zai] {
            let store = try #require(ProviderAPIKeyStore.live(
                for: provider,
                home: home,
                environment: [:],
                keychain: keychain
            ))
            #expect(store.service == "com.omo.usage.provider-api-keys.v1")
            #expect(store.account == "\(provider.rawValue)/\(AccountID.legacy.rawValue)")
        }
    }

    @Test
    func liveStoreHonorsXDGConfigHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyHome-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let xdgConfig = home.appending(
            path: "managed-config",
            directoryHint: .isDirectory
        )
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .openrouter,
                home: home,
                environment: ["XDG_CONFIG_HOME": xdgConfig.path]
            )
        )

        #expect(
            store.configURL
                == xdgConfig.appending(
                    path: "openusage/openrouter.json"
                )
        )
    }

    @Test
    func accountQualifiedStoresUseDistinctPrivateFiles() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyAccounts-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let firstID = try #require(AccountID(
            rawValue: "00000000-0000-0000-0000-000000000002"
        ))
        let secondID = try #require(AccountID(
            rawValue: "00000000-0000-0000-0000-000000000003"
        ))
        let keychain = APIKeyStoreFakeKeychain()
        let first = try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: firstID,
            home: home,
            environment: [:],
            keychain: keychain
        ))
        let second = try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: secondID,
            home: home,
            environment: [:],
            keychain: keychain
        ))

        try first.save("first-secret")
        try second.save("second-secret")

        #expect(first.configURL != second.configURL)
        #expect(first.load() == "first-secret")
        #expect(second.load() == "second-secret")
        #expect(
            first.configURL.path.contains(
                "/accounts/\(firstID.rawValue)/"
            )
        )
    }

    @Test
    func nonLegacyStoreIgnoresGlobalEnvironmentKey() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyEnvironmentIsolation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let accountID = AccountID()
        let keychain = APIKeyStoreFakeKeychain()
        let saved = try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: accountID,
            home: home,
            environment: [:],
            keychain: keychain
        ))
        try saved.save("account-key")
        let resolved = try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: accountID,
            home: home,
            environment: ["OPENROUTER_API_KEY": "global-key"],
            keychain: keychain
        ))

        #expect(resolved.load() == "account-key")
    }

    @Test
    func liveStoreIgnoresRelativeXDGConfigHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyRelative-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .openrouter,
                home: home,
                environment: ["XDG_CONFIG_HOME": "relative-config"]
            )
        )

        #expect(
            store.configURL
                == home.appending(
                    path: ".config/openusage/openrouter.json"
                )
        )
    }

    @Test(arguments: OpenRouterConfigFixture.allCases)
    func legacyOpenRouterLoadsSupportedConfigFormat(
        fixture: OpenRouterConfigFixture
    ) throws {
        try withOpenRouterConfigHome { home, configHome in
            try writeConfig(
                fixture.contents,
                to: fixture.url(in: configHome)
            )
            let store = try openRouterStore(
                home: home,
                configHome: configHome
            )

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "compatible-openrouter-key",
                        source: .file
                    )
            )
        }
    }

    @Test
    func legacyOpenRouterPrefersPrimaryConfigOverAlternate() throws {
        try withOpenRouterConfigHome { home, configHome in
            try writeConfig(
                #"{"key":"primary-openrouter-key"}"#,
                to: configHome.appending(
                    path: "openusage/openrouter.json"
                )
            )
            try writeConfig(
                "alternate-openrouter-key",
                to: configHome.appending(path: "openrouter/key.json")
            )
            let store = try openRouterStore(
                home: home,
                configHome: configHome
            )

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "primary-openrouter-key",
                        source: .file
                    )
            )
        }
    }

    @Test(arguments: OpenRouterInvalidPrimary.allCases)
    func legacyOpenRouterFallsBackFromInvalidPrimary(
        primary: OpenRouterInvalidPrimary
    ) throws {
        try withOpenRouterConfigHome { home, configHome in
            try writeConfig(
                primary.contents,
                to: configHome.appending(
                    path: "openusage/openrouter.json"
                )
            )
            try writeConfig(
                #"{"apiKey":"alternate-openrouter-key"}"#,
                to: configHome.appending(path: "openrouter/key.json")
            )
            let store = try openRouterStore(
                home: home,
                configHome: configHome
            )

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "alternate-openrouter-key",
                        source: .file
                    )
            )
        }
    }

    @Test
    func environmentAndExactKeychainPrecedeOpenRouterConfigs() throws {
        try withOpenRouterConfigHome { home, configHome in
            try writeConfig(
                #"{"key":"primary-openrouter-key"}"#,
                to: configHome.appending(
                    path: "openusage/openrouter.json"
                )
            )
            try writeConfig(
                "alternate-openrouter-key",
                to: configHome.appending(path: "openrouter/key.json")
            )
            let keychain = APIKeyStoreFakeKeychain()
            let saved = try openRouterStore(
                home: home,
                configHome: configHome,
                keychain: keychain
            )
            try saved.save("keychain-openrouter-key")
            let environment = try openRouterStore(
                home: home,
                configHome: configHome,
                environment: [
                    "OPENROUTER_API_KEY": "environment-openrouter-key"
                ],
                keychain: keychain
            )

            #expect(
                ResolvedAPIKey(environment.loadCredential())
                    == ResolvedAPIKey(
                        value: "environment-openrouter-key",
                        source: .environment
                    )
            )
            #expect(
                ResolvedAPIKey(saved.loadCredential())
                    == ResolvedAPIKey(
                        value: "keychain-openrouter-key",
                        source: .keychain
                    )
            )
        }
    }

    @Test
    func openRouterLegacyLifecycleCoversEveryConfigCandidate() throws {
        try withOpenRouterConfigHome { home, configHome in
            let primary = configHome.appending(
                path: "openusage/openrouter.json"
            )
            let alternate = configHome.appending(
                path: "openrouter/key.json"
            )
            try writeConfig("primary-openrouter-key", to: primary)
            try writeConfig("alternate-openrouter-key", to: alternate)
            let store = try openRouterStore(
                home: home,
                configHome: configHome
            )

            #expect(store.legacyExists)
            try store.removeLegacy()
            #expect(!store.legacyExists)
            #expect(!FileManager.default.fileExists(atPath: primary.path))
            #expect(!FileManager.default.fileExists(atPath: alternate.path))
        }
    }

    @Test
    func nonLegacyOpenRouterIgnoresGlobalConfigCandidates() throws {
        try withOpenRouterConfigHome { home, configHome in
            try writeConfig(
                #"{"key":"primary-openrouter-key"}"#,
                to: configHome.appending(
                    path: "openusage/openrouter.json"
                )
            )
            try writeConfig(
                "alternate-openrouter-key",
                to: configHome.appending(path: "openrouter/key.json")
            )
            let store = try #require(ProviderAPIKeyStore.live(
                for: .openrouter,
                accountID: AccountID(),
                home: home,
                environment: ["XDG_CONFIG_HOME": configHome.path],
                keychain: APIKeyStoreFakeKeychain()
            ))

            #expect(store.loadCredential()?.value == nil)
        }
    }

    @Test(arguments: ZAIAlternateConfigFixture.allCases)
    func legacyZAILoadsAlternateConfigFormat(
        fixture: ZAIAlternateConfigFixture
    ) throws {
        try withZAIConfigHome { home, configHome in
            try writeConfig(
                fixture.contents,
                to: configHome.appending(path: "zai/key.json")
            )
            let store = try zaiStore(home: home, configHome: configHome)

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "compatible-zai-key",
                        source: .file
                    )
            )
        }
    }

    @Test
    func legacyZAIPrefersPrimaryConfigOverAlternate() throws {
        try withZAIConfigHome { home, configHome in
            try writeConfig(
                #"{"key":"primary-zai-key"}"#,
                to: configHome.appending(path: "openusage/zai.json")
            )
            try writeConfig(
                "alternate-zai-key",
                to: configHome.appending(path: "zai/key.json")
            )
            let store = try zaiStore(home: home, configHome: configHome)

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "primary-zai-key",
                        source: .file
                    )
            )
        }
    }

    @Test(arguments: ZAIInvalidPrimary.allCases)
    func legacyZAIFallsBackFromInvalidPrimary(
        primary: ZAIInvalidPrimary
    ) throws {
        try withZAIConfigHome { home, configHome in
            try writeConfig(
                primary.contents,
                to: configHome.appending(path: "openusage/zai.json")
            )
            try writeConfig(
                #"{"apiKey":"alternate-zai-key"}"#,
                to: configHome.appending(path: "zai/key.json")
            )
            let store = try zaiStore(home: home, configHome: configHome)

            #expect(
                ResolvedAPIKey(store.loadCredential())
                    == ResolvedAPIKey(
                        value: "alternate-zai-key",
                        source: .file
                    )
            )
        }
    }

    @Test
    func environmentAndExactKeychainPrecedeZAIConfigs() throws {
        try withZAIConfigHome { home, configHome in
            try writeConfig(
                "alternate-zai-key",
                to: configHome.appending(path: "zai/key.json")
            )
            let keychain = APIKeyStoreFakeKeychain()
            let saved = try zaiStore(
                home: home,
                configHome: configHome,
                keychain: keychain
            )
            try saved.save("keychain-zai-key")
            let environment = try zaiStore(
                home: home,
                configHome: configHome,
                environment: ["ZAI_API_KEY": "environment-zai-key"],
                keychain: keychain
            )

            #expect(
                ResolvedAPIKey(environment.loadCredential())
                    == ResolvedAPIKey(
                        value: "environment-zai-key",
                        source: .environment
                    )
            )
            #expect(
                ResolvedAPIKey(saved.loadCredential())
                    == ResolvedAPIKey(
                        value: "keychain-zai-key",
                        source: .keychain
                    )
            )
        }
    }

    @Test
    func zaiLegacyLifecycleCoversEveryConfigCandidate() throws {
        try withZAIConfigHome { home, configHome in
            let primary = configHome.appending(path: "openusage/zai.json")
            let alternate = configHome.appending(path: "zai/key.json")
            try writeConfig("alternate-zai-key", to: alternate)
            let store = try zaiStore(home: home, configHome: configHome)

            #expect(store.legacyExists)
            try writeConfig("primary-zai-key", to: primary)
            try store.removeLegacy()
            #expect(!store.legacyExists)
            #expect(!FileManager.default.fileExists(atPath: primary.path))
            #expect(!FileManager.default.fileExists(atPath: alternate.path))
        }
    }

    @Test
    func nonLegacyZAIIgnoresGlobalAlternateConfig() throws {
        try withZAIConfigHome { home, configHome in
            try writeConfig(
                "alternate-zai-key",
                to: configHome.appending(path: "zai/key.json")
            )
            let store = try #require(ProviderAPIKeyStore.live(
                for: .zai,
                accountID: AccountID(),
                home: home,
                environment: ["XDG_CONFIG_HOME": configHome.path],
                keychain: APIKeyStoreFakeKeychain()
            ))

            #expect(store.loadCredential()?.value == nil)
        }
    }

    enum ZAIAlternateConfigFixture: String, CaseIterable, Sendable {
        case apiKey
        case snakeAPIKey
        case key
        case plainText

        var contents: String {
            switch self {
            case .apiKey:
                #"{"apiKey":"compatible-zai-key"}"#
            case .snakeAPIKey:
                #"{"api_key":"compatible-zai-key"}"#
            case .key:
                #"{"key":"compatible-zai-key"}"#
            case .plainText:
                "  compatible-zai-key\n"
            }
        }
    }

    enum ZAIInvalidPrimary: String, CaseIterable, Sendable {
        case malformed
        case blank

        var contents: String {
            switch self {
            case .malformed: "{not-json"
            case .blank: " \n\t "
            }
        }
    }

    enum OpenRouterConfigFixture: String, CaseIterable, Sendable {
        case primaryAPIKey
        case primarySnakeAPIKey
        case primaryKey
        case primaryPlainText
        case alternateAPIKey
        case alternateSnakeAPIKey
        case alternateKey
        case alternatePlainText

        var contents: String {
            switch self {
            case .primaryAPIKey, .alternateAPIKey:
                #"{"apiKey":"compatible-openrouter-key"}"#
            case .primarySnakeAPIKey, .alternateSnakeAPIKey:
                #"{"api_key":"compatible-openrouter-key"}"#
            case .primaryKey, .alternateKey:
                #"{"key":"compatible-openrouter-key"}"#
            case .primaryPlainText, .alternatePlainText:
                "  compatible-openrouter-key\n"
            }
        }

        func url(in configHome: URL) -> URL {
            switch self {
            case .primaryAPIKey, .primarySnakeAPIKey, .primaryKey,
                .primaryPlainText:
                configHome.appending(path: "openusage/openrouter.json")
            case .alternateAPIKey, .alternateSnakeAPIKey, .alternateKey,
                .alternatePlainText:
                configHome.appending(path: "openrouter/key.json")
            }
        }
    }

    enum OpenRouterInvalidPrimary: String, CaseIterable, Sendable {
        case malformed
        case blank

        var contents: String {
            switch self {
            case .malformed: "{not-json"
            case .blank: " \n\t "
            }
        }
    }

    private func openRouterStore(
        home: URL,
        configHome: URL,
        environment: [String: String] = [:],
        keychain: any ProviderKeychain = APIKeyStoreFakeKeychain()
    ) throws -> ProviderAPIKeyStore {
        try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            home: home,
            environment: environment.merging(
                ["XDG_CONFIG_HOME": configHome.path],
                uniquingKeysWith: { current, _ in current }
            ),
            keychain: keychain
        ))
    }

    private func zaiStore(
        home: URL,
        configHome: URL,
        environment: [String: String] = [:],
        keychain: any ProviderKeychain = APIKeyStoreFakeKeychain()
    ) throws -> ProviderAPIKeyStore {
        try #require(ProviderAPIKeyStore.live(
            for: .zai,
            home: home,
            environment: environment.merging(
                ["XDG_CONFIG_HOME": configHome.path],
                uniquingKeysWith: { current, _ in current }
            ),
            keychain: keychain
        ))
    }

    private func writeConfig(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func withOpenRouterConfigHome(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyOpenRouter-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, home.appending(path: "config"))
    }

    private func withZAIConfigHome(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderAPIKeyZAI-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, home.appending(path: "config"))
    }
}

private struct ResolvedAPIKey: Equatable {
    let value: String
    let source: CredentialSource

    init?(_ credential: (value: String, source: CredentialSource)?) {
        guard let credential else { return nil }
        value = credential.value
        source = credential.source
    }

    init(value: String, source: CredentialSource) {
        self.value = value
        self.source = source
    }
}

private final class APIKeyStoreFakeKeychain: ProviderKeychain, @unchecked Sendable {
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
