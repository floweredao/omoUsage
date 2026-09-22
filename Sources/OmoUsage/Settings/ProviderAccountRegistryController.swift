import OmoUsageCore
import Foundation
import Observation

enum ProviderAccountRegistryControllerError: Error, Equatable {
    case unsupportedProvider
    case invalidLabel
    case emptyKey
    case accountNotFound
    case cannotRemoveLegacy
    case persistenceUnavailable
    case keyStoreUnavailable
    case registryUnavailable
    case credentialUnavailable
}

enum ProviderKeyStorageSource: Equatable, Sendable {
    case environment
    case keychain
    case legacyFile
}

struct ProviderAccountMetadata: Identifiable, Equatable, Sendable {
    var id: AccountProviderID { accountProviderID }
    let accountProviderID: AccountProviderID
    let provider: ProviderID
    let label: String
    let source: ProviderKeyStorageSource?
}

struct ProviderAccountSettingsMetadata: Identifiable, Equatable, Sendable {
    var id: AccountProviderID { accountProviderID }
    let accountProviderID: AccountProviderID
    let provider: ProviderID
    let label: String
    let isPrimary: Bool
    let maskedIdentity: String?
    let source: ProviderKeyStorageSource?
}

struct AppAccountComposition {
    let providers: [any UsageProvider]
    let accountProviderOrder: [AccountProviderID]
    let disconnected: Set<AccountProviderID>
}

enum AppAccountCompositionFactory {
    static func make(
        registry: ProviderAccountRegistry?,
        providerFactory: (ProviderAccountRegistry) -> [any UsageProvider] = {
            ProviderFactory.current(registry: $0)
        }
    ) -> AppAccountComposition {
        guard let registry else {
            return AppAccountComposition(
                providers: [],
                accountProviderOrder: [],
                disconnected: []
            )
        }
        return AppAccountComposition(
            providers: providerFactory(registry),
            accountProviderOrder: registry.displayOrder,
            disconnected: Set(registry.disconnected)
        )
    }
}

@Observable
@MainActor
final class ProviderAccountRegistryController {
    @ObservationIgnored
    private let store: ProviderAccountStore
    @ObservationIgnored
    private let keyStore: (ProviderID, AccountID) -> ProviderAPIKeyStore?
    @ObservationIgnored
    private let makeAccountID: () -> AccountID
    @ObservationIgnored
    private let credentialSnapshotStore:
        () -> ProviderCredentialSnapshotStore?
    @ObservationIgnored
    private let persistenceEnabled: Bool
    @ObservationIgnored
    private let mutationCoordinator: ProviderMutationCoordinator
    @ObservationIgnored
    private let maskedIdentity: (AccountProviderID) -> String?

    private(set) var registry: ProviderAccountRegistry?
    private(set) var recoveryState: ProviderAccountRecoveryState

    init(
        store: ProviderAccountStore,
        registry: ProviderAccountRegistry,
        persistenceEnabled: Bool = true,
        keyStore: @escaping (ProviderID, AccountID) -> ProviderAPIKeyStore? = {
            ProviderAPIKeyStore.live(for: $0, accountID: $1)
        },
        makeAccountID: @escaping () -> AccountID = { AccountID() },
        credentialSnapshotStore: @escaping () -> ProviderCredentialSnapshotStore? = {
            CredentialDiscovery.live().snapshotStore
        },
        mutationAfterPhase: @escaping ProviderMutationCoordinator.PhaseHook = { _ in },
        maskedIdentity: @escaping (AccountProviderID) -> String? = { _ in nil }
    ) {
        self.store = store
        self.registry = registry
        self.recoveryState = .ready
        self.persistenceEnabled = persistenceEnabled
        self.keyStore = keyStore
        self.makeAccountID = makeAccountID
        self.credentialSnapshotStore = credentialSnapshotStore
        self.maskedIdentity = maskedIdentity
        self.mutationCoordinator = ProviderMutationCoordinator(
            store: store,
            keyStore: keyStore,
            afterPhase: mutationAfterPhase
        )
    }

    init(
        store: ProviderAccountStore,
        loadResult: ProviderAccountLoadResult,
        keyStore: @escaping (ProviderID, AccountID) -> ProviderAPIKeyStore? = {
            ProviderAPIKeyStore.live(for: $0, accountID: $1)
        },
        makeAccountID: @escaping () -> AccountID = { AccountID() },
        credentialSnapshotStore: @escaping () -> ProviderCredentialSnapshotStore? = {
            CredentialDiscovery.live().snapshotStore
        },
        mutationAfterPhase: @escaping ProviderMutationCoordinator.PhaseHook = { _ in },
        maskedIdentity: @escaping (AccountProviderID) -> String? = { _ in nil }
    ) {
        self.store = store
        self.registry = loadResult.registry
        self.recoveryState = loadResult.state
        self.persistenceEnabled = true
        self.keyStore = keyStore
        self.makeAccountID = makeAccountID
        self.credentialSnapshotStore = credentialSnapshotStore
        self.maskedIdentity = maskedIdentity
        self.mutationCoordinator = ProviderMutationCoordinator(
            store: store,
            keyStore: keyStore,
            afterPhase: mutationAfterPhase
        )
    }

    var accounts: [ProviderAccountMetadata] {
        guard let registry else { return [] }
        let accounts = Dictionary(
            uniqueKeysWithValues: registry.accounts.map { ($0.id, $0) }
        )
        return registry.providerReferences.compactMap { identity in
            guard
                identity.accountID != .legacy,
                let account = accounts[identity.accountID]
            else {
                return nil
            }
            return ProviderAccountMetadata(
                accountProviderID: identity,
                provider: identity.providerID,
                label: account.label(for: identity.providerID),
                source: keyStorageSource(for: identity)
            )
        }
    }

    func settingsAccounts(for provider: ProviderID) -> [ProviderAccountSettingsMetadata] {
        guard let registry else { return [] }
        let identities = [AccountProviderID(accountID: .legacy, providerID: provider)]
            + registry.providerReferences.filter {
                $0.providerID == provider && $0.accountID != .legacy
            }
        return identities.compactMap { identity in
            guard let account = registry.accounts.first(where: { $0.id == identity.accountID })
            else { return nil }
            return ProviderAccountSettingsMetadata(
                accountProviderID: identity,
                provider: provider,
                label: account.label(for: provider),
                isPrimary: identity.accountID == .legacy,
                maskedIdentity: maskedIdentity(identity),
                source: keyStorageSource(for: identity)
            )
        }
    }

    func renameAccount(_ identity: AccountProviderID, label rawLabel: String) throws {
        let label = try Self.validatedAccountLabel(rawLabel)
        _ = try requireRegistry()
        try replaceRegistry { registry in
            guard registry.accounts.contains(where: { $0.id == identity.accountID }),
                  identity.accountID == .legacy || registry.providerReferences.contains(identity)
            else {
                throw ProviderAccountRegistryControllerError.accountNotFound
            }
            let peers = Set(registry.providerReferences + [
                AccountProviderID(accountID: .legacy, providerID: identity.providerID)
            ])
            guard !peers.contains(where: { peer in
                peer != identity && peer.providerID == identity.providerID
                    && registry.accounts.first { $0.id == peer.accountID }?
                        .label(for: peer.providerID).caseInsensitiveCompare(label) == .orderedSame
            }) else {
                throw ProviderAccountRegistryControllerError.invalidLabel
            }
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts.map { account in
                    guard account.id == identity.accountID else { return account }
                    var labels = account.providerLabels
                    labels[identity.providerID.rawValue] = label
                    return ProviderAccount(id: account.id, label: account.label, providerLabels: labels)
                },
                displayOrder: registry.displayOrder,
                disconnected: registry.disconnected,
                providerReferences: registry.providerReferences
            )
        }
    }

    func keyStorageSource(for provider: ProviderID) -> ProviderKeyStorageSource? {
        keyStorageSource(for: AccountProviderID(accountID: .legacy, providerID: provider))
    }

    var pendingLegacyCleanup: [AccountProviderID] {
        mutationCoordinator.pendingLegacyCleanup()
    }

    func retryLegacyKeyCleanup() throws {
        try mutationCoordinator.retryLegacyCleanup()
    }

    private func keyStorageSource(for identity: AccountProviderID) -> ProviderKeyStorageSource? {
        guard let source = keyStore(identity.providerID, identity.accountID)?
            .loadCredential()?.source
        else { return nil }
        switch source {
        case .environment: return .environment
        case .keychain: return .keychain
        case .file: return .legacyFile
        }
    }

    func saveOrder(_ order: [AccountProviderID]) throws {
        _ = try requireRegistry()
        try replaceRegistry { registry in
            let repaired = AccountProviderDisplayOrder.repaired(
                order,
                configured: registry.displayOrder
            )
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: repaired,
                disconnected: registry.disconnected,
                providerReferences: registry.providerReferences
            )
        }
    }

    func saveDisconnected(_ disconnected: Set<AccountProviderID>) throws {
        _ = try requireRegistry()
        try replaceRegistry { registry in
            let valid = Set(registry.displayOrder)
            let ordered = registry.displayOrder.filter {
                disconnected.contains($0) && valid.contains($0)
            }
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: registry.displayOrder,
                disconnected: ordered,
                providerReferences: registry.providerReferences
            )
        }
    }

    /// Pins the Codex credential that currently belongs to the legacy
    /// account before the companion is allowed to replace its mutable
    /// credential. A newer official login for the same owner repairs a
    /// stale pin; another account can never displace it.
    func preserveLegacyCodexCredentialIfAbsent(
        _ encodedSecret: String
    ) throws {
        _ = try requireRegistry()
        guard
            let snapshot = try? CredentialSnapshot(
                encodedSecret: encodedSecret,
                provider: .codex
            )
        else {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
        guard let snapshotStore = credentialSnapshotStore() else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: .codex
        )
        do {
            if let stored = try snapshotStore.snapshot(for: identity),
               !snapshot.isNewerCodexCredential(than: stored) { return }
            try snapshotStore.save(snapshot, for: identity)
        } catch {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
    }

    /// Reconnect may change the legacy owner, but only after observing a
    /// changed companion login. Automatic repair must keep the same owner.
    func replaceLegacyCodexCredential(_ encodedSecret: String) throws {
        _ = try requireRegistry()
        guard
            let snapshot = try? CredentialSnapshot(
                encodedSecret: encodedSecret,
                provider: .codex
            ),
            let snapshotStore = credentialSnapshotStore()
        else {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        do {
            try snapshotStore.save(
                snapshot,
                for: AccountProviderID(
                    accountID: .legacy,
                    providerID: .codex
                )
            )
        } catch {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
    }

    func storedKiroCredential(for identity: AccountProviderID) throws -> CredentialSnapshot? {
        guard identity.providerID == .kiro else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
        guard let store = credentialSnapshotStore() else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        return try store.snapshot(for: identity)
    }

    func preserveLegacyKiroCredentialIfAbsent(_ encodedSecret: String) throws {
        _ = try requireRegistry()
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        guard let store = credentialSnapshotStore() else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        let identity = AccountProviderID(accountID: .legacy, providerID: .kiro)
        guard try store.snapshot(for: identity) == nil else { return }
        try store.save(
            CredentialSnapshot(encodedSecret: encodedSecret, provider: .kiro),
            for: identity
        )
    }

    /// An explicit import renews a captured login, never changes its profile.
    func importKiroCredential(
        _ encodedSecret: String,
        for identity: AccountProviderID,
        now: Date
    ) throws {
        guard identity.providerID == .kiro else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
        let snapshot = try CredentialSnapshot(encodedSecret: encodedSecret, provider: .kiro)
        guard let profile = snapshot.accountReference,
              let expiresAt = snapshot.expiresAt, expiresAt > now,
              !snapshot.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
        try CredentialDiscovery.validateKiroCredential(
            snapshot.credential(storage: .accountSnapshot(identity)), now: now
        )
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        guard let store = credentialSnapshotStore() else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        registry = try mutationCoordinator.writeSecret(identity: identity, key: encodedSecret) { current in
            guard current.accounts.contains(where: { $0.id == identity.accountID }),
                  identity.accountID == .legacy || current.providerReferences.contains(identity) else {
                throw ProviderAccountRegistryControllerError.accountNotFound
            }
            let stored = try store.snapshot(for: identity)
            guard (stored == nil && identity.accountID == .legacy)
                    || stored?.accountReference == profile else {
                throw ProviderAccountRegistryControllerError.credentialUnavailable
            }
            return ProviderAccountRegistry(
                version: current.version,
                migrationVersion: current.migrationVersion,
                accounts: current.accounts,
                displayOrder: current.displayOrder,
                disconnected: current.disconnected.filter { $0 != identity },
                providerReferences: current.providerReferences
            )
        }
        recoveryState = .ready
    }

    func replaceDevinCredential(
        for identity: AccountProviderID,
        encodedSecret: String
    ) throws {
        guard identity.providerID == .devin else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
        _ = try CredentialSnapshot(encodedSecret: encodedSecret, provider: .devin)
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        registry = try mutationCoordinator.writeSecret(identity: identity, key: encodedSecret) { current in
            guard current.accounts.contains(where: { $0.id == identity.accountID }),
                  identity.accountID == .legacy || current.providerReferences.contains(identity)
            else {
                throw ProviderAccountRegistryControllerError.accountNotFound
            }
            return ProviderAccountRegistry(
                version: current.version,
                migrationVersion: current.migrationVersion,
                accounts: current.accounts,
                displayOrder: current.displayOrder,
                disconnected: current.disconnected.filter { $0 != identity },
                providerReferences: current.providerReferences
            )
        }
        recoveryState = .ready
    }

    func ensureLegacyAPIKeyReference(for provider: ProviderID) throws {
        _ = try requireRegistry()
        try requireAPIKeyProvider(provider)
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: provider
        )
        try replaceRegistry { registry in
            var references = registry.providerReferences
            if !references.contains(identity) { references.append(identity) }
            var order = registry.displayOrder
            if !order.contains(identity) { order.append(identity) }
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: order,
                disconnected: registry.disconnected.filter { $0 != identity },
                providerReferences: references
            )
        }
    }

    func saveLegacyAPIKey(
        provider: ProviderID,
        key: String
    ) throws {
        _ = try requireRegistry()
        try requireAPIKeyProvider(provider)
        guard keyStore(provider, .legacy) != nil else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        let identity = AccountProviderID(accountID: .legacy, providerID: provider)
        registry = try mutationCoordinator.writeSecret(identity: identity, key: key) {
            registry in
            var references = registry.providerReferences
            if !references.contains(identity) { references.append(identity) }
            var order = registry.displayOrder
            if !order.contains(identity) { order.append(identity) }
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: order,
                disconnected: registry.disconnected.filter { $0 != identity },
                providerReferences: references
            )
        }
        recoveryState = .ready
    }

    func removeLegacyAPIKeyReference(for provider: ProviderID) throws {
        _ = try requireRegistry()
        try requireAPIKeyProvider(provider)
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: provider
        )
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        self.registry = try mutationCoordinator.removeSecret(identity: identity) {
            current in
            ProviderAccountRegistry(
                version: current.version,
                migrationVersion: current.migrationVersion,
                accounts: current.accounts,
                displayOrder: current.displayOrder,
                disconnected: current.disconnected.filter { $0 != identity },
                providerReferences: current.providerReferences.filter { $0 != identity }
            )
        }
        recoveryState = .ready
    }

    /// The one label rule every account addition goes through, so the
    /// waiting UI can reject a label before it launches anything.
    static func validatedAccountLabel(_ rawLabel: String) throws -> String {
        let trimmed = rawLabel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let label = AccountLabel.sanitized(trimmed)
        guard !trimmed.isEmpty, label == trimmed else {
            throw ProviderAccountRegistryControllerError.invalidLabel
        }
        return label
    }

    @discardableResult
    func addAPIKeyAccount(
        provider: ProviderID,
        label rawLabel: String,
        key rawKey: String?
    ) throws -> AccountProviderID {
        let label = try Self.validatedAccountLabel(rawLabel)
        guard ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == true
        else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
        let key = rawKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !key.isEmpty else {
            throw ProviderAccountRegistryControllerError.emptyKey
        }
        return try persistNewAccount(
            provider: provider,
            label: label,
            key: key
        )
    }

    /// Stores a companion credential that the caller already captured and
    /// compared against the credential present before authentication. The
    /// controller never captures on its own: a live capture here would
    /// hand the new account whichever credential the companion happens to
    /// hold, which is the account that is already connected.
    @discardableResult
    func addCapturedCompanionAccount(
        provider: ProviderID,
        label rawLabel: String,
        encodedSecret: String
    ) throws -> AccountProviderID {
        let label = try Self.validatedAccountLabel(rawLabel)
        guard ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == false
        else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
        guard
            (try? CredentialSnapshot(
                encodedSecret: encodedSecret,
                provider: provider
            )) != nil
        else {
            throw ProviderAccountRegistryControllerError.credentialUnavailable
        }
        return try persistNewAccount(
            provider: provider,
            label: label,
            key: encodedSecret
        )
    }

    @discardableResult
    private func persistNewAccount(
        provider: ProviderID,
        label: String,
        key: String
    ) throws -> AccountProviderID {
        _ = try requireRegistry()
        let accountID = makeAccountID()
        let identity = AccountProviderID(
            accountID: accountID,
            providerID: provider
        )
        guard keyStore(provider, accountID) != nil else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        self.registry = try mutationCoordinator.writeSecret(
            identity: identity,
            key: key
        ) { current in
            let accountsByID = Dictionary(
                uniqueKeysWithValues: current.accounts.map { ($0.id, $0) }
            )
            let references = current.providerReferences + [
                AccountProviderID(accountID: .legacy, providerID: provider)
            ]
            let duplicate = references.contains { reference in
                guard reference.providerID == provider,
                      let account = accountsByID[reference.accountID]
                else { return false }
                return account.label(for: provider).caseInsensitiveCompare(label) == .orderedSame
            }
            guard !duplicate else {
                throw ProviderAccountRegistryControllerError.invalidLabel
            }
            return ProviderAccountRegistry(
                version: current.version,
                migrationVersion: current.migrationVersion,
                accounts: current.accounts + [ProviderAccount(id: accountID, label: label)],
                displayOrder: current.displayOrder + [identity],
                disconnected: current.disconnected,
                providerReferences: current.providerReferences + [identity]
            )
        }
        recoveryState = .ready
        return identity
    }

    func removeAccount(_ identity: AccountProviderID) throws {
        let registry = try requireRegistry()
        guard identity.accountID != .legacy else {
            throw ProviderAccountRegistryControllerError.cannotRemoveLegacy
        }
        guard registry.providerReferences.contains(identity) else {
            throw ProviderAccountRegistryControllerError.accountNotFound
        }
        guard let secretStore = keyStore(
            identity.providerID,
            identity.accountID
        ) else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }

        _ = secretStore
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        self.registry = try mutationCoordinator.removeSecret(identity: identity) {
            current in
            guard current.providerReferences.contains(identity) else {
                throw ProviderAccountRegistryControllerError.accountNotFound
            }
            let remainingReferences = current.providerReferences.filter { $0 != identity }
            let accountStillReferenced = remainingReferences.contains {
                $0.accountID == identity.accountID
            }
            return ProviderAccountRegistry(
                version: current.version,
                migrationVersion: current.migrationVersion,
                accounts: current.accounts.filter {
                    accountStillReferenced || $0.id != identity.accountID
                },
                displayOrder: current.displayOrder.filter { $0 != identity },
                disconnected: current.disconnected.filter { $0 != identity },
                providerReferences: remainingReferences
            )
        }
        recoveryState = .ready
    }

    func removeAPIKeyAccount(_ identity: AccountProviderID) throws {
        try removeAccount(identity)
    }

    func restoreBackup() throws {
        registry = try mutationCoordinator.restoreBackup()
        recoveryState = .ready
    }

    func resetRegistry() throws {
        registry = try mutationCoordinator.resetToLegacy()
        recoveryState = .ready
    }

    private func replaceRegistry(
        _ transform: (ProviderAccountRegistry) throws -> ProviderAccountRegistry
    ) throws {
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        registry = try mutationCoordinator.mutateRegistry(transform)
        recoveryState = .ready
    }

    private func requireRegistry() throws -> ProviderAccountRegistry {
        guard let registry else {
            throw ProviderAccountRegistryControllerError.registryUnavailable
        }
        return registry
    }

    private func requireAPIKeyProvider(_ provider: ProviderID) throws {
        guard provider == .opencode || provider == .openrouter || provider == .zai
        else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
    }
}
