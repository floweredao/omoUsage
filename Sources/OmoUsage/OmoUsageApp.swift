import OmoUsageCore
import AppKit
#if OMO_USAGE_FIXTURES
import CryptoKit
import Darwin
#endif

@main
enum OmoUsageApp {
    @MainActor
    static func main() {
#if OMO_USAGE_FIXTURES
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_SINGLE_INSTANCE_FIXTURE"
        ] == "1" {
            runSingleInstanceFixture()
            return
        }
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_PROVIDER_MUTATION_FIXTURE"
        ] == "1" {
            runProviderMutationFixture()
            return
        }
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_KEY_MIGRATION_QA"
        ] == "1" {
            runProviderKeyMigrationQA()
            return
        }
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_DIAGNOSTIC_FIXTURE"
        ] == "1" {
            runDiagnosticFixture()
            return
        }
#endif

        let singleInstance: SingleInstanceController
        do {
            singleInstance = try SingleInstanceController.live()
            guard try singleInstance.claim() == .owner else {
                return
            }
        } catch {
            DiagnosticStore.shared.record(
                error: error,
                category: .singleInstance
            )
            return
        }

        let application = NSApplication.shared
        if !application.setActivationPolicy(.accessory) {
            DiagnosticStore.shared.record(
                DiagnosticEvent(
                    status: .failed,
                    category: .activationPolicy
                )
            )
        }

        let delegate = AppDelegate()
        singleInstance.installActivationHandler { [weak delegate] in
            delegate?.activateFromSecondaryLaunch()
        }
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(singleInstance) {}
    }

#if OMO_USAGE_FIXTURES
    @MainActor
    private static func runSingleInstanceFixture() {
        do {
            let singleInstance = try SingleInstanceController.live()
            let environment = ProcessInfo.processInfo.environment
            let lockAcquired: (() -> Void)? = environment[
                "OMO_USAGE_SINGLE_INSTANCE_PAUSE_AFTER_LOCK"
            ] == "1" ? { pauseSingleInstanceFixtureAfterLock() } : nil
            let tracesProtocol = environment[
                "OMO_USAGE_SINGLE_INSTANCE_TRACE_PROTOCOL"
            ] == "1"
            let activationReceived: (() -> Void)? = tracesProtocol ? {
                writeFixtureEvent("activation-received")
            } : nil
            let activationSent: (() -> Void)? = tracesProtocol ? {
                writeFixtureEvent("handoff-sent")
            } : nil
            singleInstance.installFixtureHooks(
                lockAcquired: lockAcquired,
                activationReceived: activationReceived,
                activationSent: activationSent
            )
            switch try singleInstance.claim() {
            case .owner:
                writeFixtureEvent("owner")
                singleInstance.installActivationHandler {
                    writeFixtureEvent("activation")
                    Darwin.exit(EXIT_SUCCESS)
                }
                RunLoop.main.run()
                withExtendedLifetime(singleInstance) {}
            case .contender:
                guard singleInstance.activationHandoffWasAcknowledged else {
                    writeFixtureEvent("handoff-timeout")
                    Darwin.exit(EXIT_FAILURE)
                }
                writeFixtureEvent("contender")
            }
        } catch {
            DiagnosticStore.shared.record(
                error: error,
                category: .fixture
            )
            writeFixtureEvent("error")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func pauseSingleInstanceFixtureAfterLock() {
        writeFixtureEvent("lock-acquired")
        let input = FileHandle.standardInput
        input.readabilityHandler = { handle in
            _ = handle.availableData
            handle.readabilityHandler = nil
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        input.readabilityHandler = nil
    }

    private static func runProviderMutationFixture() {
        let environment = ProcessInfo.processInfo.environment
        guard let registryPath = environment["OMO_USAGE_MUTATION_REGISTRY_PATH"],
              let providerValue = environment["OMO_USAGE_MUTATION_PROVIDER"],
              let provider = ProviderID(rawValue: providerValue),
              let defaults = UserDefaults(
                  suiteName: "ProviderMutationFixture-\(UUID().uuidString)"
              )
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        let store = ProviderAccountStore(
            registryURL: URL(filePath: registryPath),
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        let home = environment["OMO_USAGE_MUTATION_HOME"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        let fixtureKeychain = home.map {
            ProviderMutationFixtureKeychain(
                directory: $0.appending(path: ".fixture-keychain")
            )
        }
        let keyStore: ProviderMutationCoordinator.KeyStore = { provider, accountID in
            guard let home, let fixtureKeychain else { return nil }
            return ProviderAPIKeyStore.live(
                for: provider,
                accountID: accountID,
                home: home,
                environment: [:],
                keychain: fixtureKeychain
            )
        }
        let coordinator = ProviderMutationCoordinator(
            store: store,
            keyStore: keyStore,
            afterPhase: { phase in
                let isRegistryLock = environment["OMO_USAGE_MUTATION_ACTION"]
                    == "registry" && phase == .intentSynced
                let isFailpoint = environment["OMO_USAGE_MUTATION_FAILPOINT"]
                    == phase.rawValue
                guard isRegistryLock || isFailpoint else { return }
                writeFixtureEvent(isFailpoint ? phase.rawValue : "acquired")
                let shouldBlock = isFailpoint
                    || environment["OMO_USAGE_MUTATION_HOLD"] == "1"
                guard !shouldBlock
                    || FileHandle.standardInput.readData(ofLength: 1).count == 1
                else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        )
        do {
            switch environment["OMO_USAGE_MUTATION_ACTION"] ?? "registry" {
            case "add":
                let accountID = AccountID(
                    rawValue: "00000000-0000-0000-0000-000000001212"
                )!
                writeFixtureEvent("attempting")
                _ = try coordinator.addAPIKeyAccount(
                    provider: provider,
                    accountID: accountID,
                    label: "Fixture",
                    key: "provider-mutation-fixture-value"
                )
                writeFixtureEvent("completed")
            case "recover":
                let result = coordinator.loadOrRecover()
                let identity = AccountProviderID(
                    accountID: AccountID(
                        rawValue: "00000000-0000-0000-0000-000000001212"
                    )!,
                    providerID: provider
                )
                guard let registry = result.registry,
                      let secretStore = keyStore(provider, identity.accountID),
                      registry.providerReferences.contains(identity)
                          == (secretStore.load() != nil)
                else {
                    Darwin.exit(EXIT_FAILURE)
                }
                writeFixtureEvent("consistent")
            default:
                writeFixtureEvent("attempting")
                _ = try coordinator.mutateRegistry { registry in
                    let identity = AccountProviderID(
                        accountID: .legacy,
                        providerID: provider
                    )
                    return ProviderAccountRegistry(
                        version: registry.version,
                        migrationVersion: registry.migrationVersion,
                        accounts: registry.accounts,
                        displayOrder: registry.displayOrder,
                        disconnected: registry.disconnected.contains(identity)
                            ? registry.disconnected
                            : registry.disconnected + [identity],
                        providerReferences: registry.providerReferences
                    )
                }
                writeFixtureEvent("completed")
            }
        } catch {
            DiagnosticStore.shared.record(
                error: error,
                provider: provider,
                category: .fixture
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func runProviderKeyMigrationQA() {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment[
                "OMO_USAGE_KEY_MIGRATION_QA_ROOT"
              ],
              homePath.hasPrefix("/tmp/omousage-task05-qa-"),
              let service = environment[
                "OMO_USAGE_PROVIDER_KEYCHAIN_SERVICE"
              ],
              service.hasPrefix("com.omo.usage.qa.")
        else {
            writeFixtureEvent("status=invalid-fixture-configuration")
            Darwin.exit(EXIT_FAILURE)
        }

        let application = NSApplication.shared
        _ = application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let home = URL(filePath: homePath, directoryHint: .isDirectory)
        let suiteName = "ProviderKeyMigrationQA-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            writeFixtureEvent("status=defaults-unavailable")
            Darwin.exit(EXIT_FAILURE)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychain = ProviderKeyMigrationQAKeychain(
            base: SecurityProviderKeychain()
        )
        let legacyURL = home.appending(
            path: ".config/openusage/keys/openrouter.key"
        )
        let registryURL = home.appending(
            path: ".config/openusage/accounts.json"
        )
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: .openrouter
        )
        let keyStore = ProviderAPIKeyStore(
            provider: .openrouter,
            accountID: .legacy,
            serviceName: service,
            legacyURL: legacyURL,
            environment: [:],
            environmentNames: [],
            keychain: keychain,
            legacyFileSystem: LiveProviderLegacyFileSystem()
        )
        let accountStore = ProviderAccountStore(
            registryURL: registryURL,
            defaults: defaults,
            legacyAPIKeyPresence: { $0 == .openrouter }
        )
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        do {
            try keychain.remove(service: service, account: keyStore.account)
            try ProviderFileDurability.atomicWrite(
                try JSONSerialization.data(withJSONObject: ["apiKey": secret]),
                to: legacyURL,
                permissions: 0o600
            )
            writeFixtureEvent("status=seeded")
            writeFixtureEvent("source=legacy-file")
            writeFixtureEvent("file-exists=true")
            writeFixtureEvent("item-exists=false")

            _ = try accountStore.loadOrMigrate()
            let failpoint = environment[
                "OMO_USAGE_KEY_MIGRATION_FAILPOINT"
            ].flatMap(ProviderMutationPhase.init(rawValue:))
            if let failpoint {
                let interrupted = ProviderMutationCoordinator(
                    store: accountStore,
                    keyStore: { _, _ in keyStore },
                    afterPhase: { phase in
                        if phase == failpoint {
                            throw ProviderKeyMigrationQAInterruption()
                        }
                    }
                )
                _ = interrupted.loadOrRecover()
                writeFixtureEvent("status=interrupted-\(failpoint.rawValue)")
                writeFixtureEvent("source=legacy-file")
                writeFixtureEvent(
                    "file-exists=\(keyStore.legacyExists)"
                )
                writeFixtureEvent(
                    "item-exists=\(keyStore.keychainCredential() != nil)"
                )
                guard keyStore.legacyExists else {
                    throw ProviderKeyMigrationQAFailure.legacyRemovedTooEarly
                }
            }

            let coordinator = ProviderMutationCoordinator(
                store: accountStore,
                keyStore: { _, _ in keyStore }
            )
            let result = coordinator.loadOrRecover()
            let migratedKey = keyStore.keychainCredential()
            writeFixtureEvent("status=reconciled")
            writeFixtureEvent(
                "source=\(keyStore.loadCredential()?.source.qaName ?? "none")"
            )
            writeFixtureEvent("file-exists=\(keyStore.legacyExists)")
            writeFixtureEvent("item-exists=\(migratedKey != nil)")
            guard result.registry?.providerReferences.contains(identity) == true,
                  migratedKey == secret,
                  !keyStore.legacyExists
            else {
                if let status = keychain.lastStatus {
                    throw KeychainReadError(status: status)
                }
                throw ProviderKeyMigrationQAFailure.migrationIncomplete
            }
            writeFixtureEvent("status=committed")
            writeFixtureEvent("source=keychain")
            writeFixtureEvent("file-exists=false")
            writeFixtureEvent("item-exists=true")

            // Exercise the exact-item SecItemUpdate path after migration.
            try keychain.set(secret, service: service, account: keyStore.account)
            try keychain.remove(service: service, account: keyStore.account)
            try ProviderFileDurability.removeIfPresent(
                accountStore.mutationJournalURL
            )
            try ProviderFileDurability.removeIfPresent(legacyURL)
            let itemRemains = try keychain.value(
                service: service,
                account: keyStore.account
            ) != nil
            writeFixtureEvent("status=cleanup-complete")
            writeFixtureEvent("source=none")
            writeFixtureEvent("file-exists=false")
            writeFixtureEvent("item-exists=\(itemRemains)")
        } catch let error as KeychainReadError {
            writeFixtureEvent("status=keychain-failed")
            writeFixtureEvent("osstatus=\(error.status)")
            Darwin.exit(EXIT_FAILURE)
        } catch let error as ProviderKeyMigrationQAFailure {
            writeFixtureEvent("status=\(error.status)")
            Darwin.exit(EXIT_FAILURE)
        } catch {
            writeFixtureEvent("status=fixture-failed")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func runDiagnosticFixture() {
        let environment = ProcessInfo.processInfo.environment
        guard
            let destination = environment[
                "OMO_USAGE_DIAGNOSTIC_EXPORT_PATH"
            ],
            let seed = environment["OMO_USAGE_DIAGNOSTIC_SEED"]
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        let error = DiagnosticFixtureFailure(value: seed)
        DiagnosticStore.shared.record(
            error: error,
            category: .accountRegistry
        )
        DiagnosticStore.shared.record(
            error: error,
            provider: .claude,
            category: .providerRefresh,
            accountOrdinal: 1
        )
        DiagnosticStore.shared.record(
            error: error,
            category: .webListener
        )
        let action = DiagnosticExportAction(
            store: .shared,
            chooseDestination: { URL(filePath: destination) }
        )
        guard case .success(.some) = action.perform() else {
            Darwin.exit(EXIT_FAILURE)
        }
        writeFixtureEvent("exported")
    }

    private static func writeFixtureEvent(_ event: String) {
        FileHandle.standardOutput.write(Data("\(event)\n".utf8))
    }
#endif
}

#if OMO_USAGE_FIXTURES
private final class ProviderKeyMigrationQAKeychain: ProviderKeychain,
    @unchecked Sendable
{
    let base: any ProviderKeychain
    private let lock = NSLock()
    private var recordedStatus: OSStatus?

    init(base: any ProviderKeychain) { self.base = base }

    var lastStatus: OSStatus? { lock.withLock { recordedStatus } }

    func value(service: String, account: String) throws -> String? {
        try recording { try base.value(service: service, account: account) }
    }

    func set(_ value: String, service: String, account: String) throws {
        try recording { try base.set(value, service: service, account: account) }
    }

    func remove(service: String, account: String) throws {
        try recording { try base.remove(service: service, account: account) }
    }

    private func recording<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as KeychainReadError {
            lock.withLock { recordedStatus = error.status }
            throw error
        }
    }
}

private struct ProviderKeyMigrationQAInterruption: Error {}

private enum ProviderKeyMigrationQAFailure: Error {
    case legacyRemovedTooEarly
    case migrationIncomplete

    var status: String {
        switch self {
        case .legacyRemovedTooEarly: "legacy-removed-before-commit"
        case .migrationIncomplete: "migration-incomplete"
        }
    }
}

private extension CredentialSource {
    var qaName: String {
        switch self {
        case .environment: "environment"
        case .file: "legacy-file"
        case .keychain: "keychain"
        }
    }
}

private final class ProviderMutationFixtureKeychain: ProviderKeychain, @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func value(service: String, account: String) throws -> String? {
        let url = itemURL(service: service, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(data: try Data(contentsOf: url), encoding: .utf8)
    }

    func set(_ value: String, service: String, account: String) throws {
        try ProviderFileDurability.atomicWrite(
            Data(value.utf8),
            to: itemURL(service: service, account: account),
            permissions: 0o600
        )
    }

    func remove(service: String, account: String) throws {
        try ProviderFileDurability.removeIfPresent(
            itemURL(service: service, account: account)
        )
    }

    private func itemURL(service: String, account: String) -> URL {
        let digest = SHA256.hash(data: Data("\(service)|\(account)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }
}

private struct DiagnosticFixtureFailure: Error, CustomStringConvertible {
    let value: String
    var description: String { value }
}
#endif
