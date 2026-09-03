import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct ProviderAccountAdditionCoordinatorTests {
    @Test
    func launchesCompanionBeforePersistingAnyAccount() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        let outcome = coordinator.addAccount(
            provider: .codex,
            label: "Work",
            key: nil
        )

        #expect(outcome == .waitingForCompanion)
        #expect(fixture.events == ["capture:codex", "launch:codex"])
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
        #expect(fixture.refreshCount == 0)
        #expect(coordinator.pending?.provider == .codex)
        #expect(coordinator.pending?.label == "Work")

        let fingerprint = try #require(
            coordinator.pending?.credentialFingerprint
        )
        #expect(fingerprint.count == 64)
        #expect(!fixture.codexSecretA.contains(fingerprint))
        #expect(
            fingerprint.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
        )

        // One pending companion addition globally: a second companion
        // Add must not launch anything while the first one waits.
        #expect(
            coordinator.addAccount(
                provider: .claude,
                label: "Personal",
                key: nil
            ) == .additionInProgress
        )
        #expect(fixture.events == ["capture:codex", "launch:codex"])
        #expect(coordinator.pending?.provider == .codex)
    }

    @Test
    func unchangedCredentialRemainsPendingWithoutPersisting() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.events.removeAll()

        #expect(coordinator.checkAgain() == .credentialUnchanged)

        #expect(coordinator.pending?.provider == .codex)
        #expect(coordinator.pending?.label == "Work")
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
        #expect(fixture.refreshCount == 0)
        #expect(fixture.events == ["capture:codex"])

        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.notFound(.codex)
        )

        #expect(coordinator.checkAgain() == .credentialMissing)

        #expect(coordinator.pending?.provider == .codex)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
        #expect(fixture.refreshCount == 0)
    }

    @Test
    func changedCredentialPersistsFreshAccountAndRequestsRefresh() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(
            coordinator.applicationDidBecomeActive()
                == .addedAccount("Work")
        )

        #expect(coordinator.pending == nil)
        #expect(fixture.refreshCount == 1)
        let account = try #require(fixture.controller.accounts.first)
        #expect(fixture.controller.accounts.count == 1)
        #expect(account.provider == .codex)
        #expect(account.label == "Work")
        #expect(account.accountProviderID.accountID != .legacy)
        #expect(
            account.accountProviderID.accountID
                == fixture.nextAccountIDs[0]
        )
        #expect(
            fixture.keyStore(
                .codex,
                account.accountProviderID.accountID
            )?.load() == fixture.codexSecretB
        )

        // A later activation must not add a second account or ask for
        // another refresh: the pending addition is already finished.
        #expect(coordinator.applicationDidBecomeActive() == .ignored)
        #expect(fixture.controller.accounts.count == 1)
        #expect(fixture.refreshCount == 1)
    }

    @Test
    func cancelledAdditionIgnoresLaterActivation() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )

        coordinator.cancel()
        #expect(coordinator.pending == nil)

        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(coordinator.applicationDidBecomeActive() == .ignored)
        #expect(coordinator.checkAgain() == .ignored)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
        #expect(fixture.refreshCount == 0)
    }

    @Test
    func apiKeyAdditionRemainsImmediateWithoutLaunchingCompanion() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()

        let outcome = coordinator.addAccount(
            provider: .openrouter,
            label: "Team",
            key: "openrouter-secret"
        )

        #expect(outcome == .addedAccount("Team"))
        #expect(fixture.events.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(fixture.refreshCount == 1)
        let account = try #require(fixture.controller.accounts.first)
        #expect(account.provider == .openrouter)
        #expect(
            fixture.keyStore(
                .openrouter,
                account.accountProviderID.accountID
            )?.load() == "openrouter-secret"
        )

        // An API-key account stays addable while a companion addition
        // is still waiting for its credential.
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )

        #expect(
            coordinator.addAccount(
                provider: .zai,
                label: "Personal",
                key: "zai-secret"
            ) == .addedAccount("Personal")
        )
        #expect(fixture.refreshCount == 2)
        #expect(coordinator.pending?.provider == .codex)
        #expect(
            fixture.controller.accounts.map(\.provider)
                == [.openrouter, .zai]
        )
    }

    @Test
    func rejectsInvalidLabelBeforeLaunchingCompanion() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "person@example.com",
                key: nil
            ) == .invalidLabel
        )

        #expect(fixture.events.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
    }

    @Test
    func unreadableBaselineCredentialNeverLaunchesOrPersists() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.malformed(.codex)
        )

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .credentialUnavailable
        )

        #expect(fixture.events == ["capture:codex"])
        #expect(coordinator.pending == nil)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
    }

    @Test
    func missingBaselineCaptureStillWaitsForTheFirstCredential() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.notFound(.codex)
        )

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        #expect(coordinator.pending?.credentialFingerprint == nil)

        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(coordinator.checkAgain() == .addedAccount("Work"))
        #expect(
            fixture.keyStore(
                .codex,
                try #require(
                    fixture.controller.accounts.first
                ).accountProviderID.accountID
            )?.load() == fixture.codexSecretA
        )
    }

    @Test
    func failedPersistenceKeepsTheAdditionWaiting() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator(
            failingAfter: .secretStaged
        )
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(coordinator.checkAgain() == .failed)

        #expect(coordinator.pending?.provider == .codex)
        #expect(fixture.controller.accounts.isEmpty)
        // The rolled-back mutation leaves no usable account secret; the
        // staged item stays for the journal to reconcile.
        #expect(
            fixture.keyStore(
                .codex,
                fixture.nextAccountIDs[0]
            )?.load() == nil
        )
        #expect(fixture.refreshCount == 0)
    }
}

@MainActor
private final class AdditionFixture {
    let suiteName = "ProviderAccountAdditionCoordinatorTests-\(UUID().uuidString)"
    let rootURL: URL
    let homeURL: URL
    let registryURL: URL
    let defaults: UserDefaults
    let store: ProviderAccountStore
    let keychain = AdditionFakeKeychain()
    let nextAccountIDs = [
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a1")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a2")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a3")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a4")!
    ]

    var capture: [ProviderID: Result<String, CredentialDiscoveryError>] = [:]
    var launchResult: Result<ProviderSetupOutcome, ProviderSetupError> =
        .success(.launched)
    var events: [String] = []
    private(set) var refreshCount = 0
    private var accountIndex = 0
    private var failingPhase: ProviderMutationPhase?
    private var madeController: ProviderAccountRegistryController?

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
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

    var controller: ProviderAccountRegistryController {
        if let madeController { return madeController }
        let created = makeController()
        madeController = created
        return created
    }

    func makeCoordinator(
        failingAfter phase: ProviderMutationPhase? = nil
    ) -> ProviderAccountAdditionCoordinator {
        failingPhase = phase
        return ProviderAccountAdditionCoordinator(
            controller: controller,
            captureCredential: { [unowned self] provider in
                self.events.append("capture:\(provider.rawValue)")
                switch self.capture[provider] {
                case .success(let secret):
                    return secret
                case .failure(let error):
                    throw error
                case nil:
                    throw CredentialDiscoveryError.notFound(provider)
                }
            },
            launchCompanion: { [unowned self] provider in
                self.events.append("launch:\(provider.rawValue)")
                return self.launchResult
            },
            onAccountAdded: { [unowned self] in
                self.refreshCount += 1
            }
        )
    }

    private func makeController() -> ProviderAccountRegistryController {
        let phase = failingPhase
        return ProviderAccountRegistryController(
            store: store,
            registry: try! store.loadOrMigrate(),
            keyStore: { [unowned self] provider, accountID in
                self.keyStore(provider, accountID)
            },
            makeAccountID: { [unowned self] in
                defer { self.accountIndex += 1 }
                return self.nextAccountIDs[self.accountIndex]
            },
            mutationAfterPhase: { reached in
                if reached == phase { throw AdditionMutationFailure() }
            }
        )
    }

    var codexSecretA: String {
        Self.encodedCodexSecret(accessToken: "codex-access-a")
    }

    var codexSecretB: String {
        Self.encodedCodexSecret(accessToken: "codex-access-b")
    }

    func keyStore(
        _ provider: ProviderID,
        _ accountID: AccountID
    ) -> ProviderAPIKeyStore? {
        ProviderAPIKeyStore.live(
            for: provider,
            accountID: accountID,
            home: homeURL,
            environment: [:],
            keychain: keychain
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func encodedCodexSecret(accessToken: String) -> String {
        let snapshot = CredentialSnapshot(
            provider: .codex,
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            accountReference: "account-\(accessToken)",
            planName: "Plus",
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            source: .file
        )
        return (try? snapshot.encodedSecret()) ?? ""
    }
}

private struct AdditionMutationFailure: Error {}

private final class AdditionFakeKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var isEmpty: Bool { lock.withLock { values.isEmpty } }

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
