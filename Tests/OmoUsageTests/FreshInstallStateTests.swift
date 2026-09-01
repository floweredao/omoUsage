import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct FreshInstallStateTests {
    @Test
    func liveStoreCreatesCanonicalPrivateRegistryForCleanInstall() throws {
        let fixture = try FreshInstallFixture()
        defer { fixture.remove() }
        let xdgConfig = fixture.home.appending(
            path: "xdg-config",
            directoryHint: .isDirectory
        )
        let store = ProviderAccountStore.live(
            home: fixture.home,
            environment: ["XDG_CONFIG_HOME": xdgConfig.path],
            defaults: fixture.defaults,
            providerKeychain: FreshInstallMissingProviderKeychain()
        )

        let registry = try store.loadOrMigrate()

        #expect(
            store.registryURL
                == xdgConfig.appending(path: "openusage/accounts.json")
        )
        #expect(registry.accounts == [
            ProviderAccount(
                id: .legacy,
                label: AccountLabel.defaultValue
            )
        ])
        #expect(registry.displayOrder == ProviderID.allCases.map {
            AccountProviderID(accountID: .legacy, providerID: $0)
        })
        #expect(registry.disconnected.isEmpty)
        #expect(
            registry.providerReferences
                == ProviderID.allCases.prefix(7).map {
                    AccountProviderID(
                        accountID: .legacy,
                        providerID: $0
                    )
                }
        )
        #expect(try permissions(of: store.registryURL) == 0o600)
        #expect(
            try permissions(of: store.registryURL.deletingLastPathComponent())
                == 0o700
        )
    }

    @Test
    func liveStoreIgnoresRelativeXDGConfigHome() throws {
        let fixture = try FreshInstallFixture()
        defer { fixture.remove() }
        let store = ProviderAccountStore.live(
            home: fixture.home,
            environment: ["XDG_CONFIG_HOME": "relative-config"],
            defaults: fixture.defaults,
            providerKeychain: FreshInstallMissingProviderKeychain()
        )

        #expect(
            store.registryURL
                == fixture.home.appending(
                    path: ".config/openusage/accounts.json"
                )
        )
    }

    @Test
    func registryWithoutLegacyAccountIsInvalid() throws {
        let fixture = try FreshInstallFixture()
        defer { fixture.remove() }
        let registryURL = fixture.home.appending(path: "accounts.json")
        let otherAccount = AccountID()
        let data = try JSONEncoder().encode(
            ProviderAccountRegistry(
                version: ProviderAccountStore.currentVersion,
                migrationVersion:
                    ProviderAccountStore.currentMigrationVersion,
                accounts: [
                    ProviderAccount(id: otherAccount, label: "Account 2")
                ],
                displayOrder: [],
                disconnected: [],
                providerReferences: []
            )
        )
        try data.write(to: registryURL)
        let store = ProviderAccountStore(
            registryURL: registryURL,
            defaults: fixture.defaults,
            legacyAPIKeyPresence: { _ in false }
        )

        #expect(throws: ProviderAccountStoreError.invalidRegistry) {
            try store.loadOrMigrate()
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try #require(attributes[.posixPermissions] as? Int)
    }
}

private struct FreshInstallMissingProviderKeychain: ProviderKeychain {
    func value(service: String, account: String) throws -> String? { nil }
    func set(_ value: String, service: String, account: String) throws {}
    func remove(service: String, account: String) throws {}
}

private struct FreshInstallFixture {
    let suiteName: String
    let defaults: UserDefaults
    let home: URL

    init() throws {
        suiteName = "FreshInstallStateTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        home = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
    }
}
