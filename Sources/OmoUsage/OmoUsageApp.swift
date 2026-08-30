import AppKit
import CryptoKit
import Darwin

@main
enum OmoUsageApp {
    @MainActor
    static func main() {
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

    @MainActor
    private static func runSingleInstanceFixture() {
        do {
            let singleInstance = try SingleInstanceController.live()
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
                      registry.apiKeyReferences.contains(identity)
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
                        apiKeyReferences: registry.apiKeyReferences
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

    private static func runProviderKeyMigrationQA() {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment["HOME"],
              environment["OMO_USAGE_PROVIDER_KEYCHAIN_SERVICE"] != nil
        else { Darwin.exit(EXIT_FAILURE) }
        let home = URL(filePath: homePath, directoryHint: .isDirectory)
        writeFixtureEvent("migration-started")
        let qaKeychain = ProviderMigrationQAKeychain(
            reader: SecurityProviderKeychain()
        )
        let store = ProviderAccountStore.live(
            home: home,
            environment: environment,
            defaults: UserDefaults(suiteName: "ProviderKeyMigrationQA")!,
            providerKeychain: qaKeychain
        )
        let failpoint = environment["OMO_USAGE_KEY_MIGRATION_FAILPOINT"]
            .flatMap(ProviderMutationPhase.init(rawValue:))
        let coordinator = ProviderMutationCoordinator(
            store: store,
            keyStore: { provider, accountID in
                ProviderAPIKeyStore.live(
                    for: provider,
                    accountID: accountID,
                    home: home,
                    environment: environment,
                    keychain: qaKeychain
                )
            },
            afterPhase: { phase in
                if phase == failpoint { throw CocoaError(.fileWriteUnknown) }
            }
        )
        writeFixtureEvent("migration-attempting")
        let result = coordinator.loadOrRecover()
        writeFixtureEvent("migration-reconciled")
        guard result.registry != nil else { Darwin.exit(EXIT_FAILURE) }
        writeFixtureEvent(
            coordinator.pendingLegacyCleanup().isEmpty
                ? "migration-finished"
                : "cleanup-pending"
        )
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
}

private struct ProviderMigrationQAKeychain: ProviderKeychain {
    let reader: any ProviderKeychain
    func value(service: String, account: String) throws -> String? {
        try reader.value(service: service, account: account)
    }
    func set(_ value: String, service: String, account: String) throws {
        throw KeychainReadError(status: errSecReadOnly)
    }
    func remove(service: String, account: String) throws {
        throw KeychainReadError(status: errSecReadOnly)
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
