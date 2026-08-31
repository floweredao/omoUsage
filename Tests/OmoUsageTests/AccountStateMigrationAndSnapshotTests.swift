import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct AccountStateMigrationAndSnapshotTests {
    private let legacyAccountID =
        "00000000-0000-0000-0000-000000000001"

    @Test
    func reencodesLegacySnapshotWithDeterministicAccountIdentity() throws {
        let legacy = snapshotData(
            version: 1,
            accountIDs: [nil]
        )

        let decoded = try UsageSnapshotCodec.decode(legacy)
        let migrated = try UsageSnapshotCodec.encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        )
        let providers = try #require(
            object["providers"] as? [[String: Any]]
        )

        #expect(object["version"] as? Int == 4)
        #expect(providers.first?["accountOrdinal"] as? Int == 1)
        #expect(providers.first?["accountID"] == nil)
        #expect(providers.first?["accountLabel"] == nil)
    }

    @Test
    func acceptsSameProviderForDifferentAccounts() throws {
        let data = snapshotData(
            version: 2,
            accountIDs: [
                legacyAccountID,
                "00000000-0000-0000-0000-000000000002"
            ]
        )

        let decoded = try UsageSnapshotCodec.decode(data)

        #expect(decoded.providers.count == 2)
        #expect(decoded.providers.allSatisfy { $0.provider == .codex })
    }

    @Test
    func sanitizesPrivateAccountLabelsDuringSnapshotDecode() throws {
        let data = Data(
            """
            {
              "version": 2,
              "providers": [{
                "provider": "codex",
                "accountID": "00000000-0000-0000-0000-000000000002",
                "accountLabel": "person@example.com",
                "planName": "Plus",
                "groups": [],
                "availability": "available",
                "updatedAt": null
              }],
              "refreshedAt": 1786867200000
            }
            """.utf8
        )

        let decoded = try UsageSnapshotCodec.decode(data)

        #expect(decoded.providers.first?.accountLabel == "Default Account")
    }

    @Test
    func rejectsDuplicateCompositeAccountProviderIdentity() {
        let data = snapshotData(
            version: 2,
            accountIDs: [
                legacyAccountID,
                legacyAccountID
            ]
        )

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test
    func migratesLegacyStateDeterministicallyWithoutPersistingSecrets() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            ["codex", "unknown", "codex", "claude"],
            forKey: ProviderDisplayOrderStore.defaultsKey
        )
        fixture.defaults.set(
            ["claude"],
            forKey: ProviderDisconnectionStore.defaultsKey
        )
        let store = ProviderAccountStore(
            registryURL: fixture.registryURL,
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { $0 == .openrouter }
        )

        let registry = try store.loadOrMigrate()
        let persisted = try Data(contentsOf: fixture.registryURL)
        let persistedText = String(decoding: persisted, as: UTF8.self)

        #expect(registry.version == 2)
        #expect(registry.migrationVersion == 1)
        #expect(registry.accounts == [
            ProviderAccount(id: .legacy, label: "Default Account")
        ])
        #expect(
            registry.displayOrder.map(\.providerID)
                == ProviderDisplayOrder.repaired(
                    rawValues: [
                        "codex", "unknown", "codex", "claude"
                    ]
                )
        )
        #expect(registry.displayOrder.allSatisfy {
            $0.accountID == .legacy
        })
        #expect(registry.disconnected == [
            AccountProviderID(
                accountID: .legacy,
                providerID: .claude
            )
        ])
        #expect(registry.apiKeyReferences == [
            AccountProviderID(
                accountID: .legacy,
                providerID: .openrouter
            )
        ])
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.registryURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.rootURL.path
        )
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
        #expect(!persistedText.contains("secret"))
        #expect(try store.loadOrMigrate() == registry)
    }

    @Test
    func migratesOpenCodeGoAPIKeyReference() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        let store = ProviderAccountStore(
            registryURL: fixture.registryURL,
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { $0 == .opencode }
        )

        let registry = try store.loadOrMigrate()

        #expect(registry.apiKeyReferences == [
            AccountProviderID(
                accountID: .legacy,
                providerID: .opencode
            )
        ])
        #expect(try store.loadOrMigrate() == registry)
    }

    @Test
    func liveMigrationPreservesOfficialOpenCodeCredential() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        let authURL = fixture.rootURL.appending(
            path: ".local/share/opencode/auth.json"
        )
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"opencode-go":{"key":"official-opencode-key"}}"#.utf8
        ).write(to: authURL)
        let store = ProviderAccountStore.live(
            home: fixture.rootURL,
            environment: [:],
            defaults: fixture.defaults,
            providerKeychain: AccountStateMissingProviderKeychain()
        )

        let registry = try store.loadOrMigrate()

        #expect(registry.apiKeyReferences.contains(
            AccountProviderID(
                accountID: .legacy,
                providerID: .opencode
            )
        ))
    }

    @Test
    func liveMigrationPreservesOpenCodeLocalDatabase() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.rootURL.appending(
            path: ".local/share/opencode/opencode.db"
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(
            atPath: databaseURL.path,
            contents: Data()
        ))
        let store = ProviderAccountStore.live(
            home: fixture.rootURL,
            environment: [:],
            defaults: fixture.defaults,
            providerKeychain: AccountStateMissingProviderKeychain()
        )

        let registry = try store.loadOrMigrate()

        #expect(registry.apiKeyReferences.contains(
            AccountProviderID(
                accountID: .legacy,
                providerID: .opencode
            )
        ))
    }

    @Test
    func malformedLegacyDisconnectionsFailClosedWithoutChangingLegacyState() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            ["claude", "not-a-provider"],
            forKey: ProviderDisconnectionStore.defaultsKey
        )
        let store = ProviderAccountStore(
            registryURL: fixture.registryURL,
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { _ in false }
        )

        let registry = try store.loadOrMigrate()

        #expect(registry.disconnected == ProviderID.allCases.map {
            AccountProviderID(
                accountID: .legacy,
                providerID: $0
            )
        })
        #expect(
            fixture.defaults.stringArray(
                forKey: ProviderDisconnectionStore.defaultsKey
            ) == ["claude", "not-a-provider"]
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.registryURL.path
            )
        )
    }

    @Test
    func malformedCredentialReferencesFailClosed() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.rootURL,
            withIntermediateDirectories: true
        )
        try Data(
            """
            {
              "version": 2,
              "migrationVersion": 1,
              "accounts": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "label": "Default Account"
              }],
              "displayOrder": [],
              "disconnected": [],
              "apiKeyReferences": [{
                "accountID": "00000000-0000-0000-0000-000000000001",
                "providerID": "codex"
              }]
            }
            """.utf8
        ).write(to: fixture.registryURL)
        let store = ProviderAccountStore(
            registryURL: fixture.registryURL,
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { _ in false }
        )

        #expect(throws: ProviderAccountStoreError.invalidRegistry) {
            try store.loadOrMigrate()
        }
    }

    @Test
    func failedRegistryPersistenceLeavesAllLegacyStateUntouched() throws {
        let fixture = try RegistryFixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            ["codex", "claude"],
            forKey: ProviderDisplayOrderStore.defaultsKey
        )
        fixture.defaults.set(
            ["codex"],
            forKey: ProviderDisconnectionStore.defaultsKey
        )
        try FileManager.default.createDirectory(
            at: fixture.rootURL,
            withIntermediateDirectories: true
        )
        try Data("not-a-directory".utf8).write(
            to: fixture.registryURL
        )
        let store = ProviderAccountStore(
            registryURL: fixture.registryURL.appending(path: "accounts.json"),
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { $0 == .zai }
        )

        #expect(throws: (any Error).self) {
            try store.loadOrMigrate()
        }
        #expect(
            fixture.defaults.stringArray(
                forKey: ProviderDisplayOrderStore.defaultsKey
            ) == ["codex", "claude"]
        )
        #expect(
            fixture.defaults.stringArray(
                forKey: ProviderDisconnectionStore.defaultsKey
            ) == ["codex"]
        )
    }

    private func snapshotData(
        version: Int,
        accountIDs: [String?]
    ) -> Data {
        let providers = accountIDs.map { accountID -> String in
            let accountField = accountID.map {
                #","accountID":"\#($0)","accountLabel":"Account 1""#
            } ?? ""
            return """
            {
              "provider": "codex"\(accountField),
              "planName": "Plus",
              "groups": [],
              "availability": "available",
              "updatedAt": null
            }
            """
        }
        return Data(
            """
            {
              "version": \(version),
              "providers": [\(providers.joined(separator: ","))],
              "refreshedAt": 1786867200000
            }
            """.utf8
        )
    }
}

private struct AccountStateMissingProviderKeychain: ProviderKeychain {
    func value(service: String, account: String) throws -> String? { nil }
    func set(_ value: String, service: String, account: String) throws {}
    func remove(service: String, account: String) throws {}
}

private struct RegistryFixture {
    let suiteName: String
    let defaults: UserDefaults
    let rootURL: URL
    let registryURL: URL

    init() throws {
        suiteName = "ProviderAccountStoreTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        registryURL = rootURL.appending(path: "accounts.json")
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
