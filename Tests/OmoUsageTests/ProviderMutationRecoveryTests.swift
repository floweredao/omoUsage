import Foundation
import Testing
@testable import OmoUsage

@Suite(.serialized)
@MainActor
struct ProviderMutationRecoveryTests {
    private let secret = "issue-12-fixture-secret-never-journal"

    @Test
    func interruptedAddReconcilesToOldOrNewWithoutDanglingReferenceOrOrphan() throws {
        for phase in ProviderMutationPhase.allCases {
            let fixture = try MutationRecoveryFixture(test: "add-\(phase.rawValue)")
            defer { fixture.remove() }
            let identity = fixture.identity
            let coordinator = fixture.coordinator(failingAfter: phase)

            #expect(throws: ProviderMutationInjectedFailure.self) {
                _ = try coordinator.addAPIKeyAccount(
                    provider: identity.providerID,
                    accountID: identity.accountID,
                    label: "Team",
                    key: secret
                )
            }

            let journalData = try Data(contentsOf: fixture.store.mutationJournalURL)
            #expect(!journalData.contains(Data(secret.utf8)))

            let recovered = fixture.coordinator().loadOrRecover()
            let registry = try #require(recovered.registry)
            fixture.expectConsistent(registry: registry, identity: identity)
        }
    }

    @Test
    func interruptedReplacementReconcilesToOldOrNewSecret() throws {
        let oldSecret = "issue-12-old-fixture-secret"
        for phase in ProviderMutationPhase.allCases {
            let fixture = try MutationRecoveryFixture(test: "replace-\(phase.rawValue)")
            defer { fixture.remove() }
            let identity = AccountProviderID(accountID: .legacy, providerID: .openrouter)
            _ = try fixture.coordinator().writeSecret(
                identity: identity,
                key: oldSecret
            ) { registry in
                registry.addingReference(identity)
            }

            #expect(throws: ProviderMutationInjectedFailure.self) {
                _ = try fixture.coordinator(failingAfter: phase).writeSecret(
                    identity: identity,
                    key: secret
                ) { registry in registry }
            }

            let recovered = fixture.coordinator().loadOrRecover()
            #expect(recovered.registry?.apiKeyReferences.contains(identity) == true)
            let value = ProviderAPIKeyStore.live(
                for: identity.providerID,
                accountID: identity.accountID,
                home: fixture.homeURL,
                environment: [:],
                keychain: fixture.keychain
            )?.load()
            #expect(value == oldSecret || value == secret)
        }
    }

    @Test
    func interruptedRemovalReconcilesToOldOrNewWithoutDanglingReferenceOrOrphan() throws {
        for phase in ProviderMutationPhase.allCases {
            let fixture = try MutationRecoveryFixture(test: "remove-\(phase.rawValue)")
            defer { fixture.remove() }
            let identity = fixture.identity
            _ = try fixture.coordinator().addAPIKeyAccount(
                provider: identity.providerID,
                accountID: identity.accountID,
                label: "Team",
                key: secret
            )

            #expect(throws: ProviderMutationInjectedFailure.self) {
                try fixture.coordinator(failingAfter: phase)
                    .removeAPIKeyAccount(identity)
            }

            let recovered = fixture.coordinator().loadOrRecover()
            let registry = try #require(recovered.registry)
            fixture.expectConsistent(registry: registry, identity: identity)
        }
    }

    @Test
    func unsupportedRegistryRemainsBlockedWhileJournalIsPending() throws {
        let fixture = try MutationRecoveryFixture(test: "unsupported")
        defer { fixture.remove() }
        #expect(throws: ProviderMutationInjectedFailure.self) {
            _ = try fixture.coordinator(failingAfter: .intentSynced)
                .addAPIKeyAccount(
                    provider: fixture.identity.providerID,
                    accountID: fixture.identity.accountID,
                    label: "Team",
                    key: secret
                )
        }
        try Data(#"{"version":999}"#.utf8).write(to: fixture.store.registryURL)

        let result = fixture.coordinator().loadOrRecover()

        #expect(result.registry == nil)
        #expect(result.state.failure == .unsupportedVersion(999))
        #expect(FileManager.default.fileExists(atPath: fixture.store.mutationJournalURL.path))
    }
}

@Suite(.serialized)
struct ProviderMutationProcessSafetyTests {
    @Test(.timeLimit(.minutes(1)))
    func terminatedChildrenRecoverAtEveryDurablePhase() async throws {
        for phase in ProviderMutationPhase.allCases {
            let fixture = try MutationRecoveryFixture(
                test: "terminated-\(phase.rawValue)"
            )
            let processes = try MutationProcessFixture(
                registryURL: fixture.store.registryURL
            )
            defer {
                processes.cleanup()
                fixture.remove()
            }

            let mutation = try processes.launch(
                provider: .openrouter,
                action: "add",
                failpoint: phase,
                homeURL: fixture.homeURL
            )
            #expect(try await mutation.nextEvent() == "attempting")
            #expect(try await mutation.nextEvent() == phase.rawValue)
            let journal = try Data(
                contentsOf: fixture.store.mutationJournalURL
            )
            #expect(
                !journal.contains(
                    Data("provider-mutation-fixture-value".utf8)
                )
            )
            mutation.terminate()
            #expect(await mutation.terminationStatus() != 0)

            let recovery = try processes.launch(
                provider: .openrouter,
                action: "recover",
                homeURL: fixture.homeURL
            )
            #expect(try await recovery.nextEvent() == "consistent")
            #expect(await recovery.terminationStatus() == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func twoChildProcessesSerializeAtTheAdvisoryLock() async throws {
        let fixture = try MutationRecoveryFixture(test: "process-lock")
        let processes = try MutationProcessFixture(
            registryURL: fixture.store.registryURL
        )
        defer {
            processes.cleanup()
            fixture.remove()
        }

        let first = try processes.launch(provider: .claude, hold: true)
        #expect(try await first.nextEvent() == "attempting")
        #expect(try await first.nextEvent() == "acquired")

        let second = try processes.launch(provider: .codex, hold: false)
        #expect(try await second.nextEvent() == "attempting")
        try first.release()

        #expect(try await second.nextEvent() == "acquired")
        #expect(try await first.nextEvent() == "completed")
        #expect(try await second.nextEvent() == "completed")
        #expect(await first.terminationStatus() == 0)
        #expect(await second.terminationStatus() == 0)

        let registry = try fixture.store.loadOrMigrate()
        #expect(registry.disconnected.map(\.providerID).contains(.claude))
        #expect(registry.disconnected.map(\.providerID).contains(.codex))
    }
}

private final class MutationRecoveryFixture {
    let suiteName: String
    let rootURL: URL
    let homeURL: URL
    let defaults: UserDefaults
    let store: ProviderAccountStore
    let keychain = MutationFakeKeychain()
    let identity = AccountProviderID(
        accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000001200")!,
        providerID: .openrouter
    )

    init(test: String) throws {
        suiteName = "ProviderMutationRecoveryTests-\(test)-\(UUID().uuidString)"
        rootURL = FileManager.default.temporaryDirectory.appending(path: suiteName)
        homeURL = rootURL.appending(path: "home", directoryHint: .isDirectory)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = ProviderAccountStore(
            registryURL: rootURL.appending(path: "config/accounts.json"),
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        _ = try store.loadOrMigrate()
    }

    func coordinator(
        failingAfter phase: ProviderMutationPhase? = nil
    ) -> ProviderMutationCoordinator {
        ProviderMutationCoordinator(
            store: store,
            keyStore: { [unowned self] provider, accountID in
                ProviderAPIKeyStore.live(
                    for: provider,
                    accountID: accountID,
                    home: self.homeURL,
                    environment: [:],
                    keychain: self.keychain
                )
            },
            afterPhase: { reached in
                if reached == phase { throw ProviderMutationInjectedFailure() }
            }
        )
    }

    func expectConsistent(
        registry: ProviderAccountRegistry,
        identity: AccountProviderID
    ) {
        let referenced = registry.apiKeyReferences.contains(identity)
        let secretExists = ProviderAPIKeyStore.live(
            for: identity.providerID,
            accountID: identity.accountID,
            home: homeURL,
            environment: [:],
            keychain: keychain
        )?.load() != nil
        #expect(referenced == secretExists)
        #expect(registry.accounts.contains { $0.id == identity.accountID } == referenced)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ProviderMutationInjectedFailure: Error {}

private final class MutationFakeKeychain: ProviderKeychain, @unchecked Sendable {
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

private enum MutationFixtureError: Error {
    case executableNotFound
    case exitedBeforeEvent(Int32)
}

private final class MutationProcessFixture: @unchecked Sendable {
    let registryURL: URL
    private let executableURL: URL
    private let lock = NSLock()
    private var processes: [MutationFixtureProcess] = []

    init(registryURL: URL) throws {
        self.registryURL = registryURL
        let sourceFile = URL(fileURLWithPath: #filePath)
        executableURL = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".build/debug/OmoUsage")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MutationFixtureError.executableNotFound
        }
    }

    func launch(
        provider: ProviderID,
        hold: Bool = false,
        action: String = "registry",
        failpoint: ProviderMutationPhase? = nil,
        homeURL: URL? = nil
    ) throws -> MutationFixtureProcess {
        let process = try MutationFixtureProcess(
            executableURL: executableURL,
            environment: [
                "OMO_USAGE_PROVIDER_MUTATION_FIXTURE": "1",
                "OMO_USAGE_MUTATION_REGISTRY_PATH": registryURL.path,
                "OMO_USAGE_MUTATION_PROVIDER": provider.rawValue,
                "OMO_USAGE_MUTATION_HOLD": hold ? "1" : "0",
                "OMO_USAGE_MUTATION_ACTION": action,
                "OMO_USAGE_MUTATION_FAILPOINT": failpoint?.rawValue ?? "",
                "OMO_USAGE_MUTATION_HOME": homeURL?.path ?? ""
            ]
        )
        lock.withLock { processes.append(process) }
        return process
    }

    func cleanup() {
        let launched = lock.withLock { processes }
        for process in launched where process.isRunning { process.terminate() }
        for process in launched { process.waitUntilExit() }
    }
}

private final class MutationFixtureProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let events = MutationFixtureEvents()

    var isRunning: Bool { process.isRunning }

    init(executableURL: URL, environment: [String: String]) throws {
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, fixture in fixture }
        )
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let events = self.events
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                events.finishOutput()
            } else {
                events.receive(data)
            }
        }
        process.terminationHandler = { process in
            events.terminate(status: process.terminationStatus)
        }
        try process.run()
    }

    func nextEvent() async throws -> String {
        try await events.nextEvent()
    }

    func terminationStatus() async -> Int32 {
        await events.terminationStatus()
    }

    func release() throws {
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
    }

    func terminate() { process.terminate() }

    func waitUntilExit() {
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
    }
}

private final class MutationFixtureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered = Data()
    private var lines: [String] = []
    private var status: Int32?
    private var outputFinished = false
    private var eventWaiter: CheckedContinuation<String, any Error>?
    private var terminationWaiter: CheckedContinuation<Int32, Never>?

    func receive(_ data: Data) {
        let delivery: (CheckedContinuation<String, any Error>, String)? =
            lock.withLock {
                buffered.append(data)
                while let newline = buffered.firstIndex(of: 0x0a) {
                    let line = buffered[..<newline]
                    buffered.removeSubrange(...newline)
                    if let value = String(data: line, encoding: .utf8) {
                        lines.append(value)
                    }
                }
                guard let waiter = eventWaiter, !lines.isEmpty else { return nil }
                eventWaiter = nil
                return (waiter, lines.removeFirst())
            }
        if let delivery { delivery.0.resume(returning: delivery.1) }
    }

    func finishOutput() {
        let failure: (CheckedContinuation<String, any Error>, Int32)? =
            lock.withLock {
                outputFinished = true
                guard lines.isEmpty, let status, let waiter = eventWaiter else {
                    return nil
                }
                eventWaiter = nil
                return (waiter, status)
            }
        if let failure {
            failure.0.resume(
                throwing: MutationFixtureError.exitedBeforeEvent(failure.1)
            )
        }
    }

    func terminate(status: Int32) {
        let deliveries: (
            event: CheckedContinuation<String, any Error>?,
            termination: CheckedContinuation<Int32, Never>?
        ) = lock.withLock {
            self.status = status
            let event = outputFinished && lines.isEmpty ? eventWaiter : nil
            if event != nil { eventWaiter = nil }
            let termination = terminationWaiter
            terminationWaiter = nil
            return (event, termination)
        }
        deliveries.event?.resume(
            throwing: MutationFixtureError.exitedBeforeEvent(status)
        )
        deliveries.termination?.resume(returning: status)
    }

    func nextEvent() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<String, any Error>? = lock.withLock {
                if !lines.isEmpty { return .success(lines.removeFirst()) }
                if outputFinished, let status {
                    return .failure(MutationFixtureError.exitedBeforeEvent(status))
                }
                precondition(eventWaiter == nil)
                eventWaiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func terminationStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            let value: Int32? = lock.withLock {
                if let status { return status }
                precondition(terminationWaiter == nil)
                terminationWaiter = continuation
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}

private extension ProviderAccountRegistry {
    func addingReference(_ identity: AccountProviderID) -> ProviderAccountRegistry {
        ProviderAccountRegistry(
            version: version,
            migrationVersion: migrationVersion,
            accounts: accounts,
            displayOrder: displayOrder.contains(identity)
                ? displayOrder
                : displayOrder + [identity],
            disconnected: disconnected,
            apiKeyReferences: apiKeyReferences.contains(identity)
                ? apiKeyReferences
                : apiKeyReferences + [identity]
        )
    }
}
