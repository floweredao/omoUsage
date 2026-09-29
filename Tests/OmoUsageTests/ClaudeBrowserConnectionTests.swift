import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct ClaudeBrowserConnectionTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test(arguments: [false, true])
    func connectStoresGrantAsAppOwnedSnapshotOnly(legacy: Bool) async throws {
        let keychain = ClaudeConnectionKeychain()
        let accountID = legacy ? AccountID.legacy : AccountID()
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: keychain),
            authenticate: { snapshot("browser-access") },
            registerAccount: { _, _ in
                Issue.record("An existing account must not register a new one")
                return AccountID()
            }
        )

        let connected = try await coordinator.connect(target: .existing(accountID))

        #expect(connected == accountID)
        #expect(coordinator.pending == nil)
        let key = "claude/\(accountID.rawValue)"
        #expect(keychain.writes == [ClaudeConnectionKeychain.Access(service: ProviderAPIKeyStore.serviceName, account: key)])
        let stored = try #require(
            try ProviderCredentialSnapshotStore(keychain: keychain).snapshot(
                for: AccountProviderID(accountID: accountID, providerID: .claude)
            )
        )
        #expect(stored.accessToken == "browser-access")
        #expect(stored.refreshToken == "browser-refresh")
        #expect(!keychain.touchedServices.contains { $0.hasPrefix("Claude Code-credentials") })
    }

    @Test
    func newAccountRegistersValidatedLabelWithEncodedSnapshot() async throws {
        let keychain = ClaudeConnectionKeychain()
        let created = AccountID()
        var registered: (label: String, secret: String)?
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: keychain),
            authenticate: { snapshot("new-access") },
            registerAccount: { label, secret in
                registered = (label, secret)
                return created
            }
        )

        #expect(try await coordinator.connect(target: .newAccount(label: "  Work  ")) == created)

        let registration = try #require(registered)
        #expect(registration.label == "Work")
        #expect(try CredentialSnapshot(encodedSecret: registration.secret, provider: .claude).accessToken == "new-access")
        #expect(keychain.touchedServices.isEmpty)
    }

    @Test
    func invalidLabelIsRejectedBeforeBrowserOpens() async {
        var authenticated = false
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: ClaudeConnectionKeychain()),
            authenticate: {
                authenticated = true
                return snapshot("unused")
            },
            registerAccount: { _, _ in AccountID() }
        )
        await #expect(throws: ProviderAccountRegistryControllerError.invalidLabel) {
            try await coordinator.connect(target: .newAccount(label: "   "))
        }
        #expect(!authenticated)
    }

    @Test(arguments: [
        ClaudeBrowserAuthenticationError.timedOut, .stateMismatch, .exchangeFailed,
        .invalidToken, .authorizationDenied
    ])
    func authenticationFailuresMapToTypedErrorsWithoutWriting(
        _ failure: ClaudeBrowserAuthenticationError
    ) async {
        let keychain = ClaudeConnectionKeychain()
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: keychain),
            authenticate: { throw failure },
            registerAccount: { _, _ in AccountID() }
        )
        let expected: ClaudeBrowserConnectionError = switch failure {
        case .timedOut: .timedOut
        case .stateMismatch: .stateMismatch
        case .exchangeFailed, .invalidToken: .exchangeFailed
        default: .authorizationFailed
        }
        await #expect(throws: expected) {
            try await coordinator.connect(target: .existing(.legacy))
        }
        #expect(keychain.writes.isEmpty)
        #expect(coordinator.pending == nil)
    }

    @Test
    func cancellationDuringSignInIsTypedAndPersistsNothing() async {
        let keychain = ClaudeConnectionKeychain()
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: keychain),
            authenticate: {
                withUnsafeCurrentTask { $0?.cancel() }
                return snapshot("late")
            },
            registerAccount: { _, _ in AccountID() }
        )
        let task = Task { @MainActor in
            try await coordinator.connect(target: .existing(.legacy))
        }
        await #expect(throws: ClaudeBrowserConnectionError.cancelled) { try await task.value }
        #expect(keychain.writes.isEmpty)
    }

    @Test
    func deniedSnapshotWriteIsStorageFailure() async {
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: ClaudeConnectionKeychain(failWrites: true)),
            authenticate: { snapshot("unsaved") },
            registerAccount: { _, _ in AccountID() }
        )
        await #expect(throws: ClaudeBrowserConnectionError.storageFailed) {
            try await coordinator.connect(target: .existing(.legacy))
        }
    }

    @Test
    func secondConnectWhilePendingIsRejected() async throws {
        let gate = ClaudeConnectionGate()
        let coordinator = ClaudeBrowserConnectionCoordinator(
            snapshotStore: ProviderCredentialSnapshotStore(keychain: ClaudeConnectionKeychain()),
            authenticate: { try await gate.wait() },
            registerAccount: { _, _ in AccountID() }
        )
        let first = Task { @MainActor in try await coordinator.connect(target: .existing(.legacy)) }
        try await gate.started()
        #expect(coordinator.pending == .existing(.legacy))
        await #expect(throws: ClaudeBrowserConnectionError.alreadyConnecting) {
            try await coordinator.connect(target: .existing(.legacy))
        }
        gate.release(snapshot("first"))
        #expect(try await first.value == .legacy)
    }

    @Test
    func settingsFeedbackDistinguishesEachFailureKind() {
        let message = ClaudeBrowserConnectionFeedback.message(for:)
        #expect(message(ClaudeBrowserConnectionError.timedOut) == .claudeSignInTimedOut)
        #expect(message(ClaudeBrowserConnectionError.cancelled) == .claudeSignInCancelled)
        #expect(message(CancellationError()) == .claudeSignInCancelled)
        #expect(message(ClaudeBrowserConnectionError.storageFailed) == .claudeSignInSaveFailed)
        for failure in [
            ClaudeBrowserConnectionError.stateMismatch, .authorizationFailed, .exchangeFailed
        ] {
            #expect(message(failure) == .claudeSignInFailed)
        }
        #expect(message(ProviderAccountRegistryControllerError.invalidLabel) == .accountAdditionFailed)
        #expect(message(ClaudeBrowserConnectionError.alreadyConnecting) == nil)
    }

    private func snapshot(_ access: String) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .claude, accessToken: access, refreshToken: "browser-refresh",
            accountReference: nil, planName: nil,
            expiresAt: now.addingTimeInterval(3600), source: .keychain
        )
    }
}

@MainActor
private final class ClaudeConnectionGate {
    private var continuation: CheckedContinuation<CredentialSnapshot, Never>?
    private let (startedStream, startedSignal) = AsyncStream.makeStream(of: Void.self)

    func wait() async throws -> CredentialSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedSignal.yield(())
        }
    }

    func started() async throws {
        var iterator = startedStream.makeAsyncIterator()
        _ = try #require(await iterator.next())
    }

    func release(_ snapshot: CredentialSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private final class ClaudeConnectionKeychain: ProviderKeychain, @unchecked Sendable {
    struct Access: Equatable {
        let service: String
        let account: String
    }

    struct Denied: Error {}

    private let lock = NSLock()
    private let failWrites: Bool
    private var values: [String: String] = [:]
    private var accessed: [Access] = []
    private var written: [Access] = []

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    var writes: [Access] { lock.withLock { written } }
    var touchedServices: [String] { lock.withLock { accessed.map(\.service) } }

    func value(service: String, account: String) throws -> String? {
        lock.withLock {
            accessed.append(Access(service: service, account: account))
            return values[service + "\u{0}" + account]
        }
    }

    func set(_ value: String, service: String, account: String) throws {
        try lock.withLock {
            accessed.append(Access(service: service, account: account))
            if failWrites { throw Denied() }
            written.append(Access(service: service, account: account))
            values[service + "\u{0}" + account] = value
        }
    }

    func remove(service: String, account: String) throws {
        lock.withLock {
            accessed.append(Access(service: service, account: account))
            _ = values.removeValue(forKey: service + "\u{0}" + account)
        }
    }
}
