import AppKit
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

        let singleInstance: SingleInstanceController
        do {
            singleInstance = try SingleInstanceController.live()
            guard try singleInstance.claim() == .owner else {
                NSLog("OmoUsage activation handoff sent")
                return
            }
            NSLog("OmoUsage interactive instance owner acquired")
        } catch {
            NSLog(
                "OmoUsage single-instance ownership failed (%@)",
                String(reflecting: type(of: error))
            )
            return
        }

        let application = NSApplication.shared
        if !application.setActivationPolicy(.accessory) {
            NSLog("OmoUsage failed to set accessory activation policy at startup")
        }

        let delegate = AppDelegate()
        singleInstance.installActivationHandler { [weak delegate] in
            delegate?.activateFromSecondaryLaunch()
            NSLog("OmoUsage activation handoff received")
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
        let keyStore: ProviderMutationCoordinator.KeyStore = { provider, accountID in
            guard let home else { return nil }
            return ProviderAPIKeyStore.live(
                for: provider,
                accountID: accountID,
                home: home,
                environment: [:]
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
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func writeFixtureEvent(_ event: String) {
        FileHandle.standardOutput.write(Data("\(event)\n".utf8))
    }
}
