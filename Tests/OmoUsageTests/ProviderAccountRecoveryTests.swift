import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ProviderAccountRecoveryTests {
    @Test
    func validPrimaryLoadsReadyAndMaintainsMatchingBackup() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let expected = fixture.registry(label: "Primary")
        let primaryBytes = try fixture.write(expected, to: fixture.registryURL)

        let result = fixture.store.loadOrRecover()

        #expect(result.registry == expected)
        #expect(result.state == .ready)
        #expect(try Data(contentsOf: fixture.store.backupURL) == primaryBytes)
    }

    @Test
    func corruptPrimaryUsesValidBackupAndPreservesPrimaryInQuarantine() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let corruptBytes = Data([0x00, 0x41, 0xff, 0x42])
        let backup = fixture.registry(label: "Backup")
        try fixture.createRegistryDirectory()
        try corruptBytes.write(to: fixture.registryURL)
        try fixture.write(backup, to: fixture.store.backupURL)

        let result = fixture.store.loadOrRecover()
        let quarantineURL = try #require(result.state.quarantineURLs.first)

        #expect(result.registry == backup)
        #expect(result.state.isRecoveredFromBackup)
        #expect(quarantineURL.lastPathComponent.hasPrefix("accounts.json.corrupt-"))
        #expect(try Data(contentsOf: quarantineURL) == corruptBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.registryURL.path))
    }

    @Test
    func corruptPrimaryAndBackupBlockWithoutLegacyMigration() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let primaryBytes = Data("bad-primary".utf8)
        let backupBytes = Data("bad-backup".utf8)
        try fixture.createRegistryDirectory()
        try primaryBytes.write(to: fixture.registryURL)
        try backupBytes.write(to: fixture.store.backupURL)

        let result = fixture.store.loadOrRecover()

        #expect(result.registry == nil)
        #expect(result.state.isBlocked)
        #expect(result.state.quarantineURLs.count == 2)
        #expect(
            result.state.quarantineURLs.contains {
                $0.lastPathComponent.hasPrefix("accounts.json.bak.corrupt-")
                    && (try? Data(contentsOf: $0)) == backupBytes
            }
        )
        #expect(
            result.state.quarantineURLs.contains {
                $0.lastPathComponent.hasPrefix("accounts.json.corrupt-")
                    && (try? Data(contentsOf: $0)) == primaryBytes
            }
        )
        #expect(fixture.legacyProbeCount == 0)
    }

    @Test
    func unsupportedFutureVersionIsQuarantinedAndBlocks() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let bytes = Data(#"{"version":999}"#.utf8)
        try fixture.createRegistryDirectory()
        try bytes.write(to: fixture.registryURL)

        let result = fixture.store.loadOrRecover()

        #expect(result.registry == nil)
        #expect(result.state.failure == .unsupportedVersion(999))
        let quarantineURL = try #require(result.state.quarantineURLs.first)
        #expect(try Data(contentsOf: quarantineURL) == bytes)
    }

    @Test
    func versionOneRegistryMigratesExplicitlyAndPersistsCurrentVersion() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let legacyID = AccountID.legacy.rawValue
        let bytes = Data(
            """
            {
              "version": 1,
              "accounts": [{"id": "\(legacyID)", "label": "Default Account"}],
              "displayOrder": [],
              "disconnected": [],
              "apiKeyReferences": []
            }
            """.utf8
        )
        try fixture.createRegistryDirectory()
        try bytes.write(to: fixture.registryURL)

        let result = fixture.store.loadOrRecover()

        #expect(result.registry?.version == ProviderAccountStore.currentVersion)
        #expect(result.registry?.migrationVersion == ProviderAccountStore.currentMigrationVersion)
        #expect(result.state == .ready)
        #expect(try Data(contentsOf: fixture.registryURL) == Data(contentsOf: fixture.store.backupURL))
    }

    @Test
    @MainActor
    func blockedStateDoesNotComposeProvidersOrPermitAccountMutation() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        try fixture.createRegistryDirectory()
        try Data("broken".utf8).write(to: fixture.registryURL)
        let result = fixture.store.loadOrRecover()
        var providerFactoryCalls = 0
        var keyStoreCalls = 0

        let composition = AppAccountCompositionFactory.make(
            registry: result.registry,
            providerFactory: { _ in
                providerFactoryCalls += 1
                return [RecoveryProvider()]
            }
        )
        let controller = ProviderAccountRegistryController(
            store: fixture.store,
            loadResult: result,
            keyStore: { _, _ in
                keyStoreCalls += 1
                return nil
            }
        )

        #expect(composition.providers.isEmpty)
        #expect(composition.accountProviderOrder.isEmpty)
        #expect(providerFactoryCalls == 0)
        #expect(throws: ProviderAccountRegistryControllerError.registryUnavailable) {
            try controller.addAPIKeyAccount(
                provider: .openrouter,
                label: "Blocked",
                key: "must-not-write"
            )
        }
        #expect(keyStoreCalls == 0)
    }

    @Test
    @MainActor
    func explicitRestorePromotesBackupAndClearsRecoveryState() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let corruptBytes = Data("corrupt-primary".utf8)
        let backup = fixture.registry(label: "Restored")
        try fixture.createRegistryDirectory()
        try corruptBytes.write(to: fixture.registryURL)
        try fixture.write(backup, to: fixture.store.backupURL)
        let controller = ProviderAccountRegistryController(
            store: fixture.store,
            loadResult: fixture.store.loadOrRecover()
        )
        let quarantineURLs = controller.recoveryState.quarantineURLs

        try controller.restoreBackup()

        #expect(controller.registry == backup)
        #expect(controller.recoveryState == .ready)
        #expect(try fixture.store.loadOrMigrate() == backup)
        #expect(try Data(contentsOf: quarantineURLs[0]) == corruptBytes)
    }

    @Test
    @MainActor
    func explicitResetCreatesFreshRegistryWithoutDeletingQuarantine() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let corruptBytes = Data("corrupt-primary".utf8)
        try fixture.createRegistryDirectory()
        try corruptBytes.write(to: fixture.registryURL)
        let controller = ProviderAccountRegistryController(
            store: fixture.store,
            loadResult: fixture.store.loadOrRecover()
        )
        let quarantineURL = try #require(
            controller.recoveryState.quarantineURLs.first
        )

        try controller.resetRegistry()

        #expect(controller.registry?.accounts.map(\.id) == [.legacy])
        #expect(controller.recoveryState == .ready)
        #expect(try Data(contentsOf: quarantineURL) == corruptBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.store.backupURL.path))
    }
}

private final class RecoveryFixture {
    let suiteName = "ProviderAccountRecoveryTests-\(UUID().uuidString)"
    let rootURL: URL
    let registryURL: URL
    let defaults: UserDefaults
    private(set) var legacyProbeCount = 0
    lazy var store = ProviderAccountStore(
        registryURL: registryURL,
        defaults: defaults,
        legacyAPIKeyPresence: { [unowned self] _ in
            self.legacyProbeCount += 1
            return false
        }
    )

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        registryURL = rootURL.appending(path: "accounts.json")
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func registry(label: String) -> ProviderAccountRegistry {
        ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: [ProviderAccount(id: .legacy, label: label)],
            displayOrder: [],
            disconnected: [],
            apiKeyReferences: []
        )
    }

    @discardableResult
    func write(_ registry: ProviderAccountRegistry, to url: URL) throws -> Data {
        try createRegistryDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: url)
        return data
    }

    func createRegistryDirectory() throws {
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct RecoveryProvider: UsageProvider {
    let id = ProviderID.openrouter

    func fetch(now: Date) async throws -> ProviderUsage {
        ProviderUsage(
            provider: id,
            planName: "",
            groups: [],
            availability: .available,
            updatedAt: now
        )
    }
}
