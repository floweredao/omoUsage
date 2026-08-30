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
}

struct ProviderAPIKeyAccountMetadata: Identifiable, Equatable, Sendable {
    var id: AccountProviderID { accountProviderID }
    let accountProviderID: AccountProviderID
    let provider: ProviderID
    let label: String
}

struct AppAccountComposition {
    let providers: [any UsageProvider]
    let accountProviderOrder: [AccountProviderID]
    let disconnected: Set<AccountProviderID>
}

enum AppAccountCompositionFactory {
    static func make(
        registry: ProviderAccountRegistry,
        providerFactory: (ProviderAccountRegistry) -> [any UsageProvider] = {
            ProviderFactory.current(registry: $0)
        }
    ) -> AppAccountComposition {
        AppAccountComposition(
            providers: providerFactory(registry),
            accountProviderOrder: registry.displayOrder,
            disconnected: Set(registry.disconnected)
        )
    }

    static func deterministicLegacyRegistry(
        providerOrder: [ProviderID],
        disconnectedProviders: Set<ProviderID>
    ) -> ProviderAccountRegistry {
        let legacyIdentities = providerOrder.map {
            AccountProviderID(accountID: .legacy, providerID: $0)
        }
        return ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: [
                ProviderAccount(
                    id: .legacy,
                    label: AccountLabel.defaultValue
                )
            ],
            displayOrder: legacyIdentities,
            disconnected: legacyIdentities.filter {
                disconnectedProviders.contains($0.providerID)
            },
            apiKeyReferences: [
                AccountProviderID(
                    accountID: .legacy,
                    providerID: .opencode
                ),
                AccountProviderID(
                    accountID: .legacy,
                    providerID: .openrouter
                ),
                AccountProviderID(
                    accountID: .legacy,
                    providerID: .zai
                )
            ]
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
    private let persistenceEnabled: Bool

    private(set) var registry: ProviderAccountRegistry

    init(
        store: ProviderAccountStore,
        registry: ProviderAccountRegistry,
        persistenceEnabled: Bool = true,
        keyStore: @escaping (ProviderID, AccountID) -> ProviderAPIKeyStore? = {
            ProviderAPIKeyStore.live(for: $0, accountID: $1)
        },
        makeAccountID: @escaping () -> AccountID = { AccountID() }
    ) {
        self.store = store
        self.registry = registry
        self.persistenceEnabled = persistenceEnabled
        self.keyStore = keyStore
        self.makeAccountID = makeAccountID
    }

    var apiKeyAccounts: [ProviderAPIKeyAccountMetadata] {
        let accounts = Dictionary(
            uniqueKeysWithValues: registry.accounts.map { ($0.id, $0) }
        )
        return registry.apiKeyReferences.compactMap { identity in
            guard
                identity.accountID != .legacy,
                let account = accounts[identity.accountID]
            else {
                return nil
            }
            return ProviderAPIKeyAccountMetadata(
                accountProviderID: identity,
                provider: identity.providerID,
                label: AccountLabel.sanitized(account.label)
            )
        }
    }

    func saveOrder(_ order: [AccountProviderID]) throws {
        let repaired = AccountProviderDisplayOrder.repaired(
            order,
            configured: registry.displayOrder
        )
        try replaceRegistry(
            ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: repaired,
                disconnected: registry.disconnected,
                apiKeyReferences: registry.apiKeyReferences
            )
        )
    }

    func saveDisconnected(_ disconnected: Set<AccountProviderID>) throws {
        let valid = Set(registry.displayOrder)
        let ordered = registry.displayOrder.filter {
            disconnected.contains($0) && valid.contains($0)
        }
        try replaceRegistry(
            ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: registry.displayOrder,
                disconnected: ordered,
                apiKeyReferences: registry.apiKeyReferences
            )
        )
    }

    func ensureLegacyAPIKeyReference(for provider: ProviderID) throws {
        try requireAPIKeyProvider(provider)
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: provider
        )
        var references = registry.apiKeyReferences
        if !references.contains(identity) {
            references.append(identity)
        }
        var order = registry.displayOrder
        if !order.contains(identity) {
            order.append(identity)
        }
        try replaceRegistry(
            ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: order,
                disconnected: registry.disconnected.filter { $0 != identity },
                apiKeyReferences: references
            )
        )
    }

    func removeLegacyAPIKeyReference(for provider: ProviderID) throws {
        try requireAPIKeyProvider(provider)
        let identity = AccountProviderID(
            accountID: .legacy,
            providerID: provider
        )
        try replaceRegistry(
            ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts,
                displayOrder: registry.displayOrder,
                disconnected: registry.disconnected.filter { $0 != identity },
                apiKeyReferences: registry.apiKeyReferences.filter {
                    $0 != identity
                }
            )
        )
    }

    @discardableResult
    func addAPIKeyAccount(
        provider: ProviderID,
        label rawLabel: String,
        key rawKey: String
    ) throws -> AccountProviderID {
        try requireAPIKeyProvider(provider)
        let trimmedLabel = rawLabel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let label = AccountLabel.sanitized(trimmedLabel)
        guard !trimmedLabel.isEmpty else {
            throw ProviderAccountRegistryControllerError.invalidLabel
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderAccountRegistryControllerError.emptyKey
        }

        let accountID = makeAccountID()
        let identity = AccountProviderID(
            accountID: accountID,
            providerID: provider
        )
        guard let secretStore = keyStore(provider, accountID) else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }
        try secretStore.save(key)

        let updated = ProviderAccountRegistry(
            version: registry.version,
            migrationVersion: registry.migrationVersion,
            accounts: registry.accounts + [
                ProviderAccount(id: accountID, label: label)
            ],
            displayOrder: registry.displayOrder + [identity],
            disconnected: registry.disconnected,
            apiKeyReferences: registry.apiKeyReferences + [identity]
        )
        do {
            try replaceRegistry(updated)
        } catch {
            let registryError = error
            try secretStore.remove()
            throw registryError
        }
        return identity
    }

    func removeAPIKeyAccount(_ identity: AccountProviderID) throws {
        guard identity.accountID != .legacy else {
            throw ProviderAccountRegistryControllerError.cannotRemoveLegacy
        }
        guard registry.apiKeyReferences.contains(identity) else {
            throw ProviderAccountRegistryControllerError.accountNotFound
        }
        guard let secretStore = keyStore(
            identity.providerID,
            identity.accountID
        ) else {
            throw ProviderAccountRegistryControllerError.keyStoreUnavailable
        }

        let previous = registry
        let remainingReferences = registry.apiKeyReferences.filter {
            $0 != identity
        }
        let accountStillReferenced = remainingReferences.contains {
            $0.accountID == identity.accountID
        }
        let updated = ProviderAccountRegistry(
            version: registry.version,
            migrationVersion: registry.migrationVersion,
            accounts: registry.accounts.filter {
                accountStillReferenced || $0.id != identity.accountID
            },
            displayOrder: registry.displayOrder.filter { $0 != identity },
            disconnected: registry.disconnected.filter { $0 != identity },
            apiKeyReferences: remainingReferences
        )
        try replaceRegistry(updated)
        do {
            try secretStore.remove()
        } catch {
            _ = try store.save(previous)
            registry = previous
            throw error
        }
    }

    private func replaceRegistry(
        _ updated: ProviderAccountRegistry
    ) throws {
        guard persistenceEnabled else {
            throw ProviderAccountRegistryControllerError.persistenceUnavailable
        }
        registry = try store.save(updated)
    }

    private func requireAPIKeyProvider(_ provider: ProviderID) throws {
        guard provider == .opencode || provider == .openrouter || provider == .zai
        else {
            throw ProviderAccountRegistryControllerError.unsupportedProvider
        }
    }
}
