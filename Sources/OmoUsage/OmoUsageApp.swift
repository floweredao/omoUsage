import OmoUsageCore
import AppKit
#if OMO_USAGE_FIXTURES
import CryptoKit
import Darwin
import LocalAuthentication
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
            "OMO_USAGE_UNIFIED_KEYCHAIN_QA"
        ] == "1" {
            runUnifiedKeychainQA()
            return
        }
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_DIAGNOSTIC_FIXTURE"
        ] == "1" {
            runDiagnosticFixture()
            return
        }
        if ProcessInfo.processInfo.environment[
            CompanionAccountFixture.headlessKey
        ] == "1" {
            runCompanionAccountAdditionQA()
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

    /// Exercises the real companion-addition coordinator inside the
    /// packaged binary against an isolated registry, Keychain, credential
    /// source, and stub companion launch. Emits only non-secret results.
    @MainActor
    private static func runCompanionAccountAdditionQA() {
        guard
            let fixture = CompanionAccountFixture.resolve(
                requestKey: CompanionAccountFixture.headlessKey
            )
        else {
            writeFixtureEvent("status=invalid-fixture-configuration")
            Darwin.exit(EXIT_FAILURE)
        }
        defer {
            fixture.defaults.removePersistentDomain(
                forName: CompanionAccountFixture.suiteName(
                    forRootPath: fixture.root.path
                )
            )
        }

        let accountIDs = [
            AccountID(rawValue: "00000000-0000-0000-0000-0000000000c1")!,
            AccountID(rawValue: "00000000-0000-0000-0000-0000000000c2")!,
            AccountID(rawValue: "00000000-0000-0000-0000-0000000000c3")!
        ]
        var accountIndex = 0
        var refreshCount = 0
        var launchCount = 0

        func fail(_ reason: String) -> Never {
            writeFixtureEvent("status=\(reason)")
            Darwin.exit(EXIT_FAILURE)
        }

        func require(_ condition: Bool, _ reason: String) {
            guard condition else { fail(reason) }
        }

        func writeToken(_ token: String, for provider: ProviderID) {
            do {
                try ProviderFileDurability.atomicWrite(
                    Data(token.utf8),
                    to: fixture.credentialURL(for: provider),
                    permissions: 0o600
                )
            } catch {
                fail("credential-seed-failed")
            }
        }

        do {
            try ProviderFileDurability.preparePrivateDirectory(fixture.root)
        } catch {
            fail("fixture-root-unavailable")
        }

        let store = fixture.accountStore()
        guard let registry = try? store.loadOrMigrate() else {
            fail("registry-unavailable")
        }
        let controller = ProviderAccountRegistryController(
            store: store,
            registry: registry,
            keyStore: fixture.keyStore,
            makeAccountID: {
                defer { accountIndex += 1 }
                return accountIDs[min(accountIndex, accountIDs.count - 1)]
            },
            credentialSnapshotStore: {
                ProviderCredentialSnapshotStore(keychain: fixture.keychain)
            }
        )
        let coordinator = ProviderAccountAdditionCoordinator(
            controller: controller,
            captureCredential: fixture.captureCredential,
            launchCompanion: { provider in
                launchCount += 1
                return fixture.launchCompanion(provider)
            },
            onAccountAdded: { refreshCount += 1 }
        )

        writeToken("qa-codex-token-a", for: .codex)
        require(
            coordinator.addAccount(
                provider: .codex,
                label: "QA Companion",
                key: nil
            ) == .waitingForCompanion,
            "launch-before-persist-failed"
        )
        require(launchCount == 1, "companion-not-launched")
        require(controller.accounts.isEmpty, "account-persisted-too-early")
        require(refreshCount == 0, "refresh-requested-too-early")
        let legacyIdentity = AccountProviderID(
            accountID: .legacy,
            providerID: .codex
        )
        let snapshotStore = ProviderCredentialSnapshotStore(
            keychain: fixture.keychain
        )
        let originalLegacySnapshot = try? snapshotStore.snapshot(
            for: legacyIdentity
        )
        require(
            originalLegacySnapshot?.accessToken == "qa-codex-token-a",
            "legacy-credential-not-preserved"
        )
        writeFixtureEvent("legacy-credential-preserved=passed")
        writeFixtureEvent("launch-before-persist=passed")

        require(
            coordinator.checkAgain() == .credentialUnchanged,
            "unchanged-credential-not-detected"
        )
        require(
            coordinator.pending?.provider == .codex,
            "unchanged-credential-dropped-pending"
        )
        require(
            controller.accounts.isEmpty,
            "unchanged-credential-persisted"
        )
        writeFixtureEvent("unchanged-remains-pending=passed")

        writeToken("qa-codex-token-b", for: .codex)
        let refreshBefore = refreshCount
        require(
            coordinator.applicationDidBecomeActive()
                == .addedAccount("QA Companion"),
            "changed-credential-not-persisted"
        )
        require(coordinator.pending == nil, "pending-not-cleared")
        let companionAccounts = controller.accounts.filter {
            $0.provider == .codex
        }
        require(companionAccounts.count == 1, "companion-account-count")
        require(
            companionAccounts[0].accountProviderID.accountID == accountIDs[0],
            "companion-account-identity"
        )
        let storedSecret = fixture.keyStore(
            .codex,
            accountIDs[0]
        )?.load()
        let expectedSecret = try? fixture.captureCredential(for: .codex)
        require(
            storedSecret != nil && storedSecret == expectedSecret,
            "companion-secret-mismatch"
        )
        let preservedAfterAddition = try? snapshotStore.snapshot(
            for: legacyIdentity
        )
        require(
            preservedAfterAddition?.accessToken == "qa-codex-token-a",
            "legacy-credential-overwritten"
        )
        require(
            (try? CredentialSnapshot(
                encodedSecret: storedSecret ?? "",
                provider: .codex
            ))?.accessToken == "qa-codex-token-b",
            "new-account-not-isolated"
        )
        writeFixtureEvent("new-account-credential-isolated=passed")
        writeFixtureEvent("changed-account-persisted=passed")
        writeFixtureEvent("refresh-count=\(refreshCount - refreshBefore)")

        let rotatedLegacy = originalLegacySnapshot?.rotated(
            accessToken: "qa-codex-token-a-rotated",
            refreshToken: "qa-codex-refresh-a-rotated",
            expiresAt: nil
        )
        if let rotatedLegacy {
            try? snapshotStore.save(rotatedLegacy, for: legacyIdentity)
        }
        require(
            (try? snapshotStore.snapshot(for: legacyIdentity))?.refreshToken
                == "qa-codex-refresh-a-rotated",
            "legacy-snapshot-not-rotated"
        )
        require(
            (try? String(
                contentsOf: fixture.credentialURL(for: .codex),
                encoding: .utf8
            )) == "qa-codex-token-b",
            "legacy-rotation-touched-companion"
        )
        writeFixtureEvent("legacy-snapshot-rotation=passed")

        var reconnectEnabled = false
        let reconnect = CodexLegacyReconnectCoordinator(
            captureCredential: { try fixture.captureCredential(for: .codex) },
            persistLegacySnapshot: {
                try controller.replaceLegacyCodexCredential($0)
            },
            launchCompanion: { fixture.launchCompanion(.codex) },
            reenable: { reconnectEnabled = true }
        )
        require(
            reconnect.start() == .waitingForCredential,
            "reconnect-launch-failed"
        )
        require(
            reconnect.checkAgain() == .credentialUnchanged
                && !reconnectEnabled,
            "reconnect-reenabled-before-change"
        )
        writeToken("qa-codex-token-c", for: .codex)
        require(
            reconnect.checkAgain() == .reconnected && reconnectEnabled,
            "reconnect-did-not-complete"
        )
        require(
            (try? snapshotStore.snapshot(for: legacyIdentity))?.accessToken
                == "qa-codex-token-c",
            "reconnect-did-not-replace-legacy"
        )
        require(
            fixture.keyStore(.codex, accountIDs[0])?.load() == storedSecret,
            "reconnect-touched-added-account"
        )
        writeFixtureEvent("reconnect-guard=passed")

        let launchesBeforeAPIKey = launchCount
        require(
            coordinator.addAccount(
                provider: .openrouter,
                label: "QA Key",
                key: "qa-openrouter-secret"
            ) == .addedAccount("QA Key"),
            "api-key-not-immediate"
        )
        require(
            launchCount == launchesBeforeAPIKey,
            "api-key-launched-companion"
        )
        require(
            controller.accounts.contains { $0.provider == .openrouter },
            "api-key-account-missing"
        )
        require(
            fixture.keyStore(.openrouter, accountIDs[1])?.load()
                == "qa-openrouter-secret",
            "api-key-secret-mismatch"
        )
        writeFixtureEvent("api-key-immediate=passed")

        require(
            coordinator.addAccount(
                provider: .codex,
                label: "QA Cancelled",
                key: nil
            ) == .waitingForCompanion,
            "cancellation-setup-failed"
        )
        coordinator.cancel()
        require(coordinator.pending == nil, "cancellation-left-pending")
        writeToken("qa-codex-token-d", for: .codex)
        let accountsBeforeActivation = controller.accounts.count
        let refreshBeforeActivation = refreshCount
        require(
            coordinator.applicationDidBecomeActive() == .ignored,
            "cancelled-addition-still-active"
        )
        require(
            controller.accounts.count == accountsBeforeActivation,
            "cancelled-addition-persisted"
        )
        require(
            refreshCount == refreshBeforeActivation,
            "cancelled-addition-refreshed"
        )
        writeFixtureEvent("cancellation=passed")

        do {
            try controller.resetRegistry()
        } catch {
            fail("registry-reset-failed")
        }
        require(
            (try? snapshotStore.snapshot(for: legacyIdentity))?.accessToken
                == "qa-codex-token-c",
            "registry-reset-removed-legacy-pin"
        )
        writeFixtureEvent("registry-reset-preserves-legacy-pin=passed")
        writeFixtureEvent("status=passed")
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

    /// Exercises UnifiedProviderKeychain against the real login Keychain
    /// under QA-scoped services only: seeds legacy per-service items, proves
    /// the lazy import consolidates them into exactly one item, proves CRUD
    /// keeps a single item, and removes everything it created.
    private static func runUnifiedKeychainQA() {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment[
                "OMO_USAGE_UNIFIED_KEYCHAIN_QA_ROOT"
              ],
              root.hasPrefix("/tmp/omousage-unified-qa-"),
              let service = environment[
                "OMO_USAGE_UNIFIED_QA_SERVICE"
              ],
              service.hasPrefix("com.omo.usage.qa."),
              let legacyService = environment[
                "OMO_USAGE_UNIFIED_QA_LEGACY_SERVICE"
              ],
              legacyService.hasPrefix("com.omo.usage.qa.")
        else {
            writeFixtureEvent("status=invalid-fixture-configuration")
            Darwin.exit(EXIT_FAILURE)
        }

        let api = SecurityFrameworkItemAPI()
        let legacy = SecurityProviderKeychain(api: api)
        let unified = UnifiedProviderKeychain(
            api: api,
            service: service,
            legacyServices: [legacyService]
        )

        func itemCount(_ forService: String) -> Int {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: forService,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                SecurityKeychainAuthenticationUIPolicy.queryKey:
                    SecurityKeychainAuthenticationUIPolicy.failValue,
            ]
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            guard status == errSecSuccess,
                  let items = value as? [[String: Any]] else { return 0 }
            return items.count
        }

        func fail(_ reason: String) -> Never {
            writeFixtureEvent("status=failed reason=\(reason)")
            try? unified.remove(service: legacyService, account: "a")
            try? unified.remove(service: legacyService, account: "b")
            try? unified.remove(service: "svc2", account: "c")
            try? legacy.remove(service: legacyService, account: "a")
            try? legacy.remove(service: legacyService, account: "b")
            Darwin.exit(EXIT_FAILURE)
        }

        do {
            try? legacy.remove(service: legacyService, account: "a")
            try? legacy.remove(service: legacyService, account: "b")
            try legacy.set("sa", service: legacyService, account: "a")
            try legacy.set("sb", service: legacyService, account: "b")
            guard itemCount(legacyService) == 2 else {
                fail("legacy-seed")
            }
            writeFixtureEvent("status=legacy-seeded items=\(itemCount(legacyService))")

            let context = LAContext()
            context.interactionNotAllowed = true
            func enumProbe(_ label: String, _ extra: [String: Any]) {
                var q: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecReturnAttributes as String: true,
                    kSecReturnPersistentRef as String: true,
                    kSecMatchLimit as String: kSecMatchLimitAll,
                ]
                for (k, v) in extra { q[k] = v }
                var v: CFTypeRef?
                let s = SecItemCopyMatching(q as CFDictionary, &v)
                writeFixtureEvent(
                    "status=\(label) os=\(s) " +
                    "rows=\((v as? [[String: Any]])?.count ?? -1)"
                )
            }
            enumProbe("enum-plain", [:])
            enumProbe("enum-ctx", [
                kSecUseAuthenticationContext as String: context,
            ])
            enumProbe("enum-uif", [
                SecurityKeychainAuthenticationUIPolicy.queryKey:
                    SecurityKeychainAuthenticationUIPolicy.failValue,
            ])
            enumProbe("enum-both", [
                kSecUseAuthenticationContext as String: context,
                SecurityKeychainAuthenticationUIPolicy.queryKey:
                    SecurityKeychainAuthenticationUIPolicy.failValue,
            ])

            // Fresh-state cleanup must not run through the unified store:
            // its lazy import is once-per-instance, so touching it before
            // seeding would spend the attempt on an empty keychain.
            var staleValue: CFTypeRef?
            if SecItemCopyMatching(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "all",
                ] as CFDictionary,
                &staleValue
            ) == errSecSuccess {
                SecItemDelete(
                    [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service,
                        kSecAttrAccount as String: "all",
                    ] as CFDictionary
                )
            }

            let readA = try unified.value(
                service: legacyService, account: "a"
            )
            var payloadValue: CFTypeRef?
            let payloadStatus = SecItemCopyMatching(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "all",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ] as CFDictionary,
                &payloadValue
            )
            writeFixtureEvent(
                "status=payload-debug os=\(payloadStatus) " +
                "bytes=\((payloadValue as? Data)?.count ?? -1) " +
                "readA=\(readA ?? "nil")"
            )
            guard readA == "sa" else { fail("import-a") }
            guard try unified.value(
                service: legacyService, account: "b"
            ) == "sb" else { fail("import-b") }
            writeFixtureEvent("status=imported")

            guard itemCount(service) == 1 else {
                fail("consolidated-count=\(itemCount(service))")
            }
            writeFixtureEvent("status=single-item items=\(itemCount(service))")

            try unified.set("sc", service: "svc2", account: "c")
            guard try unified.value(service: "svc2", account: "c") == "sc"
            else { fail("write-c") }
            guard itemCount(service) == 1 else {
                fail("post-write-count=\(itemCount(service))")
            }
            writeFixtureEvent("status=written items=\(itemCount(service))")

            try unified.remove(service: legacyService, account: "a")
            try unified.remove(service: legacyService, account: "b")
            try unified.remove(service: "svc2", account: "c")
            guard itemCount(service) == 0 else {
                fail("post-remove-count=\(itemCount(service))")
            }
            writeFixtureEvent("status=cleaned items=\(itemCount(service))")
            try? legacy.remove(service: legacyService, account: "a")
            try? legacy.remove(service: legacyService, account: "b")
            writeFixtureEvent(
                "status=legacy-cleaned items=\(itemCount(legacyService))"
            )
            writeFixtureEvent("status=passed")
            Darwin.exit(EXIT_SUCCESS)
        } catch let error as KeychainReadError {
            writeFixtureEvent("status=failed reason=thrown keychain=\(error.status)")
            Darwin.exit(EXIT_FAILURE)
        } catch {
            writeFixtureEvent("status=failed reason=thrown \(error)")
            Darwin.exit(EXIT_FAILURE)
        }
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
