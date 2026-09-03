import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct ProviderAccountRegistryControllerTests {
    @Test
    func addsCapturedAccountsForEveryCompanionProvider() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        let companionProviders = ProviderID.allCases.filter {
            ProviderSetup.descriptor(for: $0)?.acceptsAPIKey == false
        }

        for provider in companionProviders {
            let secret = try ControllerFixture.encodedSecret(
                provider: provider,
                accessToken: "captured-\(provider.rawValue)"
            )
            let identity = try controller.addCapturedCompanionAccount(
                provider: provider,
                label: "\(provider.displayName) Account",
                encodedSecret: secret
            )
            #expect(
                fixture.keyStore(provider, identity.accountID)?.load()
                    == secret
            )
        }

        #expect(controller.accounts.map(\.provider) == companionProviders)
    }

    @Test
    func capturedCompanionAccountRejectsUnusableOrMisfiledSecrets() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        let codexSecret = try ControllerFixture.encodedSecret(
            provider: .codex,
            accessToken: "codex-token"
        )

        #expect(
            throws:
                ProviderAccountRegistryControllerError.credentialUnavailable
        ) {
            try controller.addCapturedCompanionAccount(
                provider: .claude,
                label: "Misfiled",
                encodedSecret: codexSecret
            )
        }
        #expect(
            throws:
                ProviderAccountRegistryControllerError.credentialUnavailable
        ) {
            try controller.addCapturedCompanionAccount(
                provider: .codex,
                label: "Unusable",
                encodedSecret: "not-a-credential"
            )
        }
        #expect(
            throws:
                ProviderAccountRegistryControllerError.unsupportedProvider
        ) {
            try controller.addCapturedCompanionAccount(
                provider: .openrouter,
                label: "API Key Provider",
                encodedSecret: codexSecret
            )
        }
        #expect(
            throws:
                ProviderAccountRegistryControllerError.unsupportedProvider
        ) {
            try controller.addAPIKeyAccount(
                provider: .codex,
                label: "Companion Provider",
                key: "manual-secret"
            )
        }

        #expect(controller.accounts.isEmpty)
        #expect(
            fixture.keyStore(
                .codex,
                fixture.nextAccountIDs[0]
            )?.load() == nil
        )
    }

    @Test
    func addsTwoAccountsForOneProviderWithDistinctPrivateKeysAndLabels() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()

        let first = try controller.addAPIKeyAccount(
            provider: .openrouter,
            label: " Work ",
            key: "first-secret"
        )
        let second = try controller.addAPIKeyAccount(
            provider: .openrouter,
            label: "Personal",
            key: "second-secret"
        )

        #expect(first != second)
        #expect(controller.accounts.map(\.label) == ["Work", "Personal"])
        #expect(controller.accounts.map(\.provider) == [.openrouter, .openrouter])
        #expect(fixture.keyStore(.openrouter, first.accountID)?.load() == "first-secret")
        #expect(fixture.keyStore(.openrouter, second.accountID)?.load() == "second-secret")
        #expect(
            fixture.keyStore(.openrouter, first.accountID)?.configURL
                != fixture.keyStore(.openrouter, second.accountID)?.configURL
        )
        #expect(
            fixture.keyStore(
                .openrouter,
                first.accountID,
                environment: ["OPENROUTER_API_KEY": "global-secret"]
            )?.load() == "first-secret"
        )
        #expect(!String(data: try Data(contentsOf: fixture.registryURL), encoding: .utf8)!.contains("secret"))
    }

    @Test
    func failedRegistrySaveRollsBackNewAccountKey() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController(
            failingAfter: .secretStaged
        )
        let accountID = fixture.nextAccountIDs[0]

        #expect(throws: ControllerMutationFailure.self) {
            try controller.addAPIKeyAccount(
                provider: .zai,
                label: "Team",
                key: "rollback-secret"
            )
        }

        #expect(fixture.keyStore(.zai, accountID)?.load() == nil)
        #expect(controller.accounts.isEmpty)
    }

    @Test
    func removingOneAccountLeavesSiblingAndRejectsLegacy() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        let first = try controller.addAPIKeyAccount(
            provider: .opencode,
            label: "First",
            key: "first-key"
        )
        let second = try controller.addAPIKeyAccount(
            provider: .opencode,
            label: "Second",
            key: "second-key"
        )

        try controller.removeAPIKeyAccount(first)

        #expect(fixture.keyStore(.opencode, first.accountID)?.load() == nil)
        #expect(fixture.keyStore(.opencode, second.accountID)?.load() == "second-key")
        #expect(controller.accounts.map(\.id) == [second])
        #expect(throws: ProviderAccountRegistryControllerError.cannotRemoveLegacy) {
            try controller.removeAPIKeyAccount(
                AccountProviderID(accountID: .legacy, providerID: .opencode)
            )
        }
    }

    @Test
    func staleControllersReloadInsideLockWithoutLosingMutations() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let first = try fixture.makeController()
        let second = try fixture.makeController()

        try first.ensureLegacyAPIKeyReference(for: .openrouter)
        try second.ensureLegacyAPIKeyReference(for: .zai)

        let persisted = try fixture.store.loadOrMigrate()
        #expect(
            persisted.providerReferences.contains(
                AccountProviderID(accountID: .legacy, providerID: .openrouter)
            )
        )
        #expect(
            persisted.providerReferences.contains(
                AccountProviderID(accountID: .legacy, providerID: .zai)
            )
        )
    }

    @Test
    func persistsOrderDisconnectionsAndLegacyReference() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        let identity = AccountProviderID(accountID: .legacy, providerID: .openrouter)

        try controller.ensureLegacyAPIKeyReference(for: .openrouter)
        try controller.saveOrder([identity])
        try controller.saveDisconnected([identity])

        let persisted = try fixture.store.loadOrMigrate()
        #expect(persisted.providerReferences.contains(identity))
        #expect(persisted.displayOrder.first == identity)
        #expect(persisted.disconnected == [identity])
    }

    @Test
    func failedLegacyReferenceSaveRestoresPreviousKey() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let legacyStore = try #require(
            fixture.keyStore(.openrouter, .legacy)
        )
        try legacyStore.save("previous-key")
        let controller = try fixture.makeController(
            persistenceEnabled: false
        )

        #expect(
            throws:
                ProviderAccountRegistryControllerError
                .persistenceUnavailable
        ) {
            try controller.saveLegacyAPIKey(
                provider: .openrouter,
                key: "replacement-key"
            )
        }

        #expect(legacyStore.load() == "previous-key")
    }

    @Test
    func failedLegacyReferenceSaveRemovesNewKey() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let legacyStore = try #require(
            fixture.keyStore(.zai, .legacy)
        )
        let controller = try fixture.makeController(
            persistenceEnabled: false
        )

        #expect(
            throws:
                ProviderAccountRegistryControllerError
                .persistenceUnavailable
        ) {
            try controller.saveLegacyAPIKey(
                provider: .zai,
                key: "new-key"
            )
        }

        #expect(legacyStore.load() == nil)
    }

    @Test
    func rejectsInvalidAccountLabelsWithoutWritingKeys() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        let invalidLabels = [
            "person@example.com",
            "../team",
            #"team\private"#,
            "~private",
            String(repeating: "a", count: 129)
        ]

        for label in invalidLabels {
            #expect(
                throws:
                    ProviderAccountRegistryControllerError.invalidLabel
            ) {
                try controller.addAPIKeyAccount(
                    provider: .openrouter,
                    label: label,
                    key: "must-not-persist"
                )
            }
        }

        #expect(controller.accounts.isEmpty)
        #expect(
            fixture.keyStore(
                .openrouter,
                fixture.nextAccountIDs[0]
            )?.load() == nil
        )
    }

    @Test
    func rejectsDuplicateAliasesForOneProvider() throws {
        let fixture = try ControllerFixture()
        defer { fixture.remove() }
        let controller = try fixture.makeController()
        _ = try controller.addAPIKeyAccount(
            provider: .openrouter,
            label: "Team",
            key: "first-key"
        )

        #expect(
            throws:
                ProviderAccountRegistryControllerError.invalidLabel
        ) {
            try controller.addAPIKeyAccount(
                provider: .openrouter,
                label: "team",
                key: "must-not-persist"
            )
        }

        #expect(controller.accounts.map(\.label) == ["Team"])
        #expect(
            fixture.keyStore(
                .openrouter,
                fixture.nextAccountIDs[1]
            )?.load() == nil
        )
    }
}

@Suite
@MainActor
struct AccountCompositionTests {
    @Test
    func compositionUsesRegistryFactoryOrderAndDisconnections() {
        let account = AccountID(rawValue: "00000000-0000-0000-0000-00000000000a")!
        let identity = AccountProviderID(accountID: account, providerID: .openrouter)
        let legacy = AccountProviderID(accountID: .legacy, providerID: .claude)
        let registry = ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: 1,
            accounts: [
                ProviderAccount(id: .legacy, label: "Default Account"),
                ProviderAccount(id: account, label: "Team")
            ],
            displayOrder: [identity, legacy],
            disconnected: [identity],
            providerReferences: [identity]
        )
        var received: ProviderAccountRegistry?

        let composition = AppAccountCompositionFactory.make(
            registry: registry,
            providerFactory: {
                received = $0
                return [
                    CompositionProvider(id: .claude, accountID: .legacy),
                    CompositionProvider(id: .openrouter, accountID: account)
                ]
            }
        )

        #expect(received == registry)
        #expect(composition.accountProviderOrder == [identity, legacy])
        #expect(composition.disconnected == [identity])
        #expect(composition.providers.map(\.accountProviderID) == [legacy, identity])
    }
}

private final class ControllerFixture {
    let suiteName = "ProviderAccountRegistryControllerTests-\(UUID().uuidString)"
    let rootURL: URL
    let homeURL: URL
    let registryURL: URL
    let defaults: UserDefaults
    let store: ProviderAccountStore
    let keychain = ControllerFakeKeychain()
    let nextAccountIDs = [
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000a")!,
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000b")!,
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000c")!,
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000d")!,
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000e")!,
        AccountID(rawValue: "00000000-0000-0000-0000-00000000000f")!,
        AccountID(rawValue: "00000000-0000-0000-0000-000000000010")!,
        AccountID(rawValue: "00000000-0000-0000-0000-000000000011")!
    ]
    private var accountIndex = 0

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        homeURL = rootURL.appending(path: "home", directoryHint: .isDirectory)
        registryURL = rootURL.appending(path: "registry/accounts.json")
        defaults = UserDefaults(suiteName: suiteName)!
        store = ProviderAccountStore(
            registryURL: registryURL,
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        _ = try store.loadOrMigrate()
    }

    static func encodedSecret(
        provider: ProviderID,
        accessToken: String
    ) throws -> String {
        try CredentialSnapshot(
            provider: provider,
            accessToken: accessToken,
            refreshToken: nil,
            accountReference: nil,
            planName: nil,
            expiresAt: nil,
            source: .file
        ).encodedSecret()
    }

    @MainActor
    func makeController(
        persistenceEnabled: Bool = true,
        failingAfter phase: ProviderMutationPhase? = nil
    ) throws -> ProviderAccountRegistryController {
        ProviderAccountRegistryController(
            store: store,
            registry: try store.loadOrMigrate(),
            persistenceEnabled: persistenceEnabled,
            keyStore: { [unowned self] provider, accountID in
                self.keyStore(provider, accountID)
            },
            makeAccountID: { [unowned self] in
                defer { self.accountIndex += 1 }
                return self.nextAccountIDs[self.accountIndex]
            },
            mutationAfterPhase: { reached in
                if reached == phase { throw ControllerMutationFailure() }
            }
        )
    }

    func keyStore(
        _ provider: ProviderID,
        _ accountID: AccountID,
        environment: [String: String] = [:]
    ) -> ProviderAPIKeyStore? {
        ProviderAPIKeyStore.live(
            for: provider,
            accountID: accountID,
            home: homeURL,
            environment: environment,
            keychain: keychain
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ControllerMutationFailure: Error {}

private final class ControllerFakeKeychain: ProviderKeychain, @unchecked Sendable {
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

private struct CompositionProvider: UsageProvider {
    let id: ProviderID
    let accountID: AccountID
    var accountLabel: String { "Account" }

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
