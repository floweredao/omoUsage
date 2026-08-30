import Foundation

struct ProviderAccount: Identifiable, Equatable, Codable, Sendable {
    let id: AccountID
    let label: String

    init(id: AccountID, label: String) {
        self.id = id
        self.label = AccountLabel.sanitized(label)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AccountID.self, forKey: .id)
        label = AccountLabel.sanitized(
            try container.decode(String.self, forKey: .label)
        )
    }
}

struct ProviderAccountRegistry: Equatable, Codable, Sendable {
    let version: Int
    let migrationVersion: Int
    let accounts: [ProviderAccount]
    let displayOrder: [AccountProviderID]
    let disconnected: [AccountProviderID]
    let apiKeyReferences: [AccountProviderID]
}

enum ProviderAccountStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidRegistry
    case invalidLegacyState
    case readbackMismatch
}

struct ProviderAccountStore {
    static let currentVersion = 2
    static let currentMigrationVersion = 1

    let registryURL: URL
    let defaults: UserDefaults
    let legacyAPIKeyPresence: (ProviderID) throws -> Bool

    init(
        registryURL: URL,
        defaults: UserDefaults,
        legacyAPIKeyPresence: @escaping (ProviderID) throws -> Bool = {
            ProviderAPIKeyStore.live(for: $0)?.load() != nil
        }
    ) {
        self.registryURL = registryURL
        self.defaults = defaults
        self.legacyAPIKeyPresence = legacyAPIKeyPresence
    }

    static func live(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> ProviderAccountStore {
        let configHome: URL
        if
            let value = environment["XDG_CONFIG_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.hasPrefix("/")
        {
            configHome = URL(
                filePath: value,
                directoryHint: .isDirectory
            )
        } else {
            configHome = home.appending(
                path: ".config",
                directoryHint: .isDirectory
            )
        }

        return ProviderAccountStore(
            registryURL: configHome.appending(
                path: "openusage/accounts.json"
            ),
            defaults: defaults,
            legacyAPIKeyPresence: { provider in
                ProviderAPIKeyStore.live(
                    for: provider,
                    home: home,
                    environment: environment
                )?.load() != nil
            }
        )
    }

    func loadOrMigrate() throws -> ProviderAccountRegistry {
        if FileManager.default.fileExists(atPath: registryURL.path) {
            return try loadRegistry()
        }

        let registry = try makeLegacyRegistry()
        try validate(registry)
        try persist(registry)
        let persisted = try loadRegistry()
        guard persisted == registry else {
            throw ProviderAccountStoreError.readbackMismatch
        }
        return persisted
    }

    @discardableResult
    func save(
        _ registry: ProviderAccountRegistry
    ) throws -> ProviderAccountRegistry {
        try validate(registry)
        try persist(registry)
        let persisted = try loadRegistry()
        guard persisted == registry else {
            throw ProviderAccountStoreError.readbackMismatch
        }
        return persisted
    }

    @discardableResult
    func saveDisplayOrder(
        _ order: [AccountProviderID]
    ) throws -> ProviderAccountRegistry {
        let registry = try loadRegistry()
        let accountIDs = Set(registry.accounts.map(\.id))
        let validOrder = order.filter {
            accountIDs.contains($0.accountID)
        }
        let repaired = AccountProviderDisplayOrder.repaired(
            validOrder,
            configured: registry.displayOrder
        )
        let updated = ProviderAccountRegistry(
            version: registry.version,
            migrationVersion: registry.migrationVersion,
            accounts: registry.accounts,
            displayOrder: repaired,
            disconnected: registry.disconnected,
            apiKeyReferences: registry.apiKeyReferences
        )
        return try save(updated)
    }

    private func loadRegistry() throws -> ProviderAccountRegistry {
        let registry: ProviderAccountRegistry
        do {
            let data = try Data(contentsOf: registryURL)
            registry = try JSONDecoder().decode(
                ProviderAccountRegistry.self,
                from: data
            )
        } catch let error as ProviderAccountStoreError {
            throw error
        } catch {
            throw ProviderAccountStoreError.invalidRegistry
        }
        guard registry.version == Self.currentVersion else {
            throw ProviderAccountStoreError.unsupportedVersion(
                registry.version
            )
        }
        try validate(registry)
        return registry
    }

    private func makeLegacyRegistry() throws -> ProviderAccountRegistry {
        let rawOrder = defaults.stringArray(
            forKey: ProviderDisplayOrderStore.defaultsKey
        ) ?? []
        let order = ProviderDisplayOrder.repaired(rawValues: rawOrder).map {
            AccountProviderID(accountID: .legacy, providerID: $0)
        }

        let disconnectedProviders: Set<ProviderID>
        if defaults.object(
            forKey: ProviderDisconnectionStore.defaultsKey
        ) == nil {
            disconnectedProviders = []
        } else if
            let values = defaults.stringArray(
                forKey: ProviderDisconnectionStore.defaultsKey
            ),
            let providers = try? strictProviders(values)
        {
            disconnectedProviders = providers
        } else {
            disconnectedProviders = Set(ProviderID.allCases)
        }
        let disconnected = ProviderID.allCases.compactMap { provider in
            disconnectedProviders.contains(provider)
                ? AccountProviderID(
                    accountID: .legacy,
                    providerID: provider
                )
                : nil
        }

        let apiKeyReferences = try ProviderID.allCases.compactMap {
            try legacyAPIKeyPresence($0)
                ? AccountProviderID(
                    accountID: .legacy,
                    providerID: $0
                )
                : nil
        }

        return ProviderAccountRegistry(
            version: Self.currentVersion,
            migrationVersion: Self.currentMigrationVersion,
            accounts: [
                ProviderAccount(
                    id: .legacy,
                    label: AccountLabel.defaultValue
                )
            ],
            displayOrder: order,
            disconnected: disconnected,
            apiKeyReferences: apiKeyReferences
        )
    }

    private func strictProviders(
        _ rawValues: [String]
    ) throws -> Set<ProviderID> {
        let providers = rawValues.compactMap(ProviderID.init(rawValue:))
        guard
            providers.count == rawValues.count,
            Set(providers).count == providers.count
        else {
            throw ProviderAccountStoreError.invalidLegacyState
        }
        return Set(providers)
    }

    private func validate(
        _ registry: ProviderAccountRegistry
    ) throws {
        guard
            registry.migrationVersion == Self.currentMigrationVersion,
            !registry.accounts.isEmpty,
            Set(registry.accounts.map(\.id)).count
                == registry.accounts.count,
            registry.accounts.allSatisfy({
                $0.label == AccountLabel.sanitized($0.label)
            })
        else {
            throw ProviderAccountStoreError.invalidRegistry
        }

        let accountIDs = Set(registry.accounts.map(\.id))
        guard
            accountIDs.contains(.legacy),
            validReferences(registry.displayOrder, accountIDs: accountIDs),
            validReferences(registry.disconnected, accountIDs: accountIDs),
            validReferences(
                registry.apiKeyReferences,
                accountIDs: accountIDs
            ),
            registry.apiKeyReferences.allSatisfy({
                $0.providerID == .opencode
                    || $0.providerID == .openrouter
                    || $0.providerID == .zai
            })
        else {
            throw ProviderAccountStoreError.invalidRegistry
        }
    }

    private func validReferences(
        _ values: [AccountProviderID],
        accountIDs: Set<AccountID>
    ) -> Bool {
        Set(values).count == values.count
            && values.allSatisfy { accountIDs.contains($0.accountID) }
    }

    private func persist(_ registry: ProviderAccountRegistry) throws {
        let directory = registryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(
            to: registryURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: registryURL.path
        )
    }
}
