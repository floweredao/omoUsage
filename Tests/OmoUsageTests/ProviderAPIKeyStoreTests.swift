import Foundation
import Testing
@testable import OmoUsage

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
