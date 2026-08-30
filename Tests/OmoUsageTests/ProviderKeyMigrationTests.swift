import Foundation
import Security
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct ProviderKeyMigrationTests {
    private let secret = "issue-5-synthetic-secret"

    @Test
    func keychainPrecedesLegacyFileWithoutOverwritingIt() throws {
        let fixture = try ProviderKeyMigrationFixture(test: "precedence")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)
        try fixture.keychain.set("keychain-wins", service: fixture.store.service, account: fixture.store.account)

        let loaded = try #require(fixture.store.loadCredential())

        #expect(loaded.value == "keychain-wins")
        #expect(loaded.source == .keychain)
        #expect(try fixture.legacyValue() == secret)
    }

    @Test
    func exactLegacyValueMigratesAndFileIsDeletedAfterCommit() throws {
        let fixture = try ProviderKeyMigrationFixture(test: "exact")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)

        let result = fixture.coordinator().loadOrRecover()

        #expect(result.registry != nil)
        #expect(try fixture.keychain.value(service: fixture.store.service, account: fixture.store.account) == secret)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.accountStore.mutationJournalURL.path))
    }

    @Test(arguments: [errSecDuplicateItem, errSecInteractionNotAllowed])
    func keychainLookupFailureNeverFallsBackOrDeletesLegacy(status: OSStatus) throws {
        let fixture = try ProviderKeyMigrationFixture(test: "lookup-\(status)")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)
        fixture.keychain.readError = KeychainReadError(status: status)

        #expect(fixture.store.loadCredential() == nil)
        _ = fixture.coordinator().loadOrRecover()

        #expect(try fixture.legacyValue() == secret)
    }

    @Test
    func registrySaveFailureRollsBackStagingAndPreservesLegacy() throws {
        let fixture = try ProviderKeyMigrationFixture(test: "registry-failure")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)
        fixture.failRegistrySave = true

        _ = fixture.coordinator().loadOrRecover()

        #expect(try fixture.legacyValue() == secret)
        #expect(try fixture.keychain.value(service: fixture.store.service, account: fixture.store.account) == nil)
        #expect(fixture.keychain.accounts.allSatisfy { !$0.contains("staging") })
    }

    @Test
    func interruptionAtEveryPhaseRetainsLegacyUntilRecoveryThenConverges() throws {
        for phase in ProviderMutationPhase.allCases {
            let fixture = try ProviderKeyMigrationFixture(test: "phase-\(phase.rawValue)")
            defer { fixture.remove() }
            try fixture.seedLegacy(secret)

            _ = fixture.coordinator(failingAfter: phase).loadOrRecover()
            #expect(try fixture.legacyValue() == secret)

            _ = fixture.coordinator().loadOrRecover()
            #expect(try fixture.keychain.value(service: fixture.store.service, account: fixture.store.account) == secret)
            #expect(!FileManager.default.fileExists(atPath: fixture.store.legacyURL.path))
            #expect(fixture.keychain.accounts.allSatisfy { !$0.contains("staging") })
        }
    }

    @Test
    func legacyDeleteFailureSurfacesCleanupAndExplicitRetryClearsIt() throws {
        let fixture = try ProviderKeyMigrationFixture(test: "cleanup")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)
        fixture.files.failRemove = true

        _ = fixture.coordinator().loadOrRecover()

        #expect(try fixture.keychain.value(service: fixture.store.service, account: fixture.store.account) == secret)
        #expect(try fixture.legacyValue() == secret)
        #expect(fixture.coordinator().pendingLegacyCleanup() == [fixture.identity])

        fixture.files.failRemove = false
        try fixture.coordinator().retryLegacyCleanup()

        #expect(!FileManager.default.fileExists(atPath: fixture.store.legacyURL.path))
        #expect(fixture.coordinator().pendingLegacyCleanup().isEmpty)
    }

    @Test
    func migrationCreatesNoPlaintextStagingFilesAndKeepsRegistryPrivate() throws {
        let fixture = try ProviderKeyMigrationFixture(test: "permissions")
        defer { fixture.remove() }
        try fixture.seedLegacy(secret)

        _ = fixture.coordinator().loadOrRecover()

        let directory = fixture.accountStore.registryURL.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.allSatisfy { !$0.contains("staging") })
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.accountStore.registryURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try Data(contentsOf: fixture.accountStore.registryURL).contains(Data(secret.utf8)) == false)
    }
}

private final class ProviderKeyMigrationFixture {
    let root: URL
    let defaults: UserDefaults
    let keychain = MigrationFakeKeychain()
    let files = MigrationFaultFileSystem()
    let accountStore: ProviderAccountStore
    var failRegistrySave = false
    let identity = AccountProviderID(accountID: .legacy, providerID: .openrouter)
    lazy var store = ProviderAPIKeyStore.live(
        for: .openrouter,
        home: root,
        environment: [:],
        keychain: keychain,
        legacyFileSystem: files
    )!

    init(test: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ProviderKeyMigration-\(test)-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "ProviderKeyMigration-\(UUID().uuidString)")!
        accountStore = ProviderAccountStore(
            registryURL: root.appending(path: ".config/openusage/accounts.json"),
            defaults: defaults,
            legacyAPIKeyPresence: { provider in provider == .openrouter }
        )
        _ = try accountStore.loadOrMigrate()
    }

    func seedLegacy(_ value: String) throws {
        try ProviderFileDurability.atomicWrite(
            JSONSerialization.data(withJSONObject: ["apiKey": value]),
            to: store.legacyURL,
            permissions: 0o600
        )
    }

    func legacyValue() throws -> String? {
        guard FileManager.default.fileExists(atPath: store.legacyURL.path) else { return nil }
        let object = try UsageJSON.object(Data(contentsOf: store.legacyURL))
        return object["apiKey"] as? String
    }

    func coordinator(failingAfter phase: ProviderMutationPhase? = nil) -> ProviderMutationCoordinator {
        ProviderMutationCoordinator(
            store: accountStore,
            keyStore: { [unowned self] _, _ in self.store },
            afterPhase: { reached in
                if reached == phase { throw MigrationInjectedFailure() }
            },
            saveRegistry: { [unowned self] registry in
                if self.failRegistrySave { throw MigrationRegistrySaveFailure() }
                return try self.accountStore.save(registry)
            }
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
        try? FileManager.default.removeItem(at: root)
    }
}

private struct MigrationInjectedFailure: Error {}
private struct MigrationRegistrySaveFailure: Error {}

private final class MigrationFakeKeychain: ProviderKeychain, @unchecked Sendable {
    private var values: [String: String] = [:]
    var readError: (any Error)?
    var accounts: [String] { Array(values.keys) }

    func value(service: String, account: String) throws -> String? {
        if let readError { throw readError }
        return values[service + "|" + account]
    }

    func set(_ value: String, service: String, account: String) throws {
        values[service + "|" + account] = value
    }

    func remove(service: String, account: String) throws {
        values[service + "|" + account] = nil
    }
}

private final class MigrationFaultFileSystem: ProviderLegacyFileSystem, @unchecked Sendable {
    var failRemove = false

    func data(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func exists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove(at url: URL) throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        try ProviderFileDurability.removeIfPresent(url)
    }
}
