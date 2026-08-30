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
    case registryUnavailable
}

enum ProviderAccountRecoveryFailure: Equatable, Sendable {
    case invalidRegistry
    case unsupportedVersion(Int)
    case fileOperationFailed
}

enum ProviderAccountRecoveryState: Equatable, Sendable {
    case ready
    case recoveredFromBackup(quarantineURLs: [URL])
    case blocked(
        failure: ProviderAccountRecoveryFailure,
        quarantineURLs: [URL]
    )

    var quarantineURLs: [URL] {
        switch self {
        case .ready:
            []
        case .recoveredFromBackup(let urls), .blocked(_, let urls):
            urls
        }
    }

    var failure: ProviderAccountRecoveryFailure? {
        guard case .blocked(let failure, _) = self else { return nil }
        return failure
    }

    var isRecoveredFromBackup: Bool {
        if case .recoveredFromBackup = self { return true }
        return false
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

struct ProviderAccountLoadResult: Equatable, Sendable {
    let registry: ProviderAccountRegistry?
    let state: ProviderAccountRecoveryState
}

struct ProviderAccountStore {
    static let currentVersion = 2
    static let currentMigrationVersion = 1

    let registryURL: URL
    let defaults: UserDefaults
    let legacyAPIKeyPresence: (ProviderID) throws -> Bool

    var backupURL: URL {
        URL(filePath: registryURL.path + ".bak")
    }

    var mutationJournalURL: URL {
        URL(filePath: registryURL.path + ".mutation-journal")
    }

    var mutationLockURL: URL {
        URL(filePath: registryURL.path + ".mutation-lock")
    }

    var existingQuarantineURLsForMutation: [URL] {
        existingQuarantineURLs()
    }

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
        defaults: UserDefaults = .standard,
        providerKeychain: any ProviderKeychain = SecurityProviderKeychain()
    ) -> ProviderAccountStore {
        let configHome: URL
        if
            let value = environment["XDG_CONFIG_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.hasPrefix("/")
        {
            configHome = URL(filePath: value, directoryHint: .isDirectory)
        } else {
            configHome = home.appending(path: ".config", directoryHint: .isDirectory)
        }

        return ProviderAccountStore(
            registryURL: configHome.appending(path: "openusage/accounts.json"),
            defaults: defaults,
            legacyAPIKeyPresence: { provider in
                if ProviderAPIKeyStore.live(
                    for: provider,
                    home: home,
                    environment: environment,
                    keychain: providerKeychain
                )?.load() != nil {
                    return true
                }
                guard provider == .opencode else { return false }
                do {
                    _ = try CredentialDiscovery.live(
                        home: home,
                        environment: environment
                    ).opencode()
                    return true
                } catch CredentialDiscoveryError.notFound(.opencode) {
                    return false
                } catch {
                    return true
                }
            }
        )
    }

    func loadOrRecover() -> ProviderAccountLoadResult {
        let fileManager = FileManager.default
        let primaryExists = fileManager.fileExists(atPath: registryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists {
            do {
                let loaded = try loadRegistry(at: registryURL)
                try persistValidated(loaded.registry)
                return ProviderAccountLoadResult(registry: loaded.registry, state: .ready)
            } catch {
                let primaryFailure = recoveryFailure(for: error)
                guard let primaryQuarantine = try? quarantine(registryURL) else {
                    return ProviderAccountLoadResult(
                        registry: nil,
                        state: .blocked(
                            failure: .fileOperationFailed,
                            quarantineURLs: []
                        )
                    )
                }
                if case .unsupportedVersion = primaryFailure {
                    return ProviderAccountLoadResult(
                        registry: nil,
                        state: .blocked(
                            failure: primaryFailure,
                            quarantineURLs: [primaryQuarantine]
                        )
                    )
                }
                guard backupExists else {
                    return ProviderAccountLoadResult(
                        registry: nil,
                        state: .blocked(
                            failure: primaryFailure,
                            quarantineURLs: [primaryQuarantine]
                        )
                    )
                }
                do {
                    let backup = try loadRegistry(at: backupURL)
                    if backup.wasMigrated {
                        try persistBackup(backup.registry)
                    }
                    return ProviderAccountLoadResult(
                        registry: backup.registry,
                        state: .recoveredFromBackup(
                            quarantineURLs: [primaryQuarantine]
                        )
                    )
                } catch {
                    guard let backupQuarantine = try? quarantine(backupURL) else {
                        return ProviderAccountLoadResult(
                            registry: nil,
                            state: .blocked(
                                failure: .fileOperationFailed,
                                quarantineURLs: [primaryQuarantine]
                            )
                        )
                    }
                    return ProviderAccountLoadResult(
                        registry: nil,
                        state: .blocked(
                            failure: primaryFailure,
                            quarantineURLs: [primaryQuarantine, backupQuarantine]
                        )
                    )
                }
            }
        }

        if backupExists {
            do {
                let backup = try loadRegistry(at: backupURL)
                if backup.wasMigrated {
                    try persistBackup(backup.registry)
                }
                return ProviderAccountLoadResult(
                    registry: backup.registry,
                    state: .recoveredFromBackup(
                        quarantineURLs: existingQuarantineURLs()
                    )
                )
            } catch {
                let failure = recoveryFailure(for: error)
                let existing = existingQuarantineURLs()
                let quarantined = (try? quarantine(backupURL)).map { [$0] } ?? []
                return ProviderAccountLoadResult(
                    registry: nil,
                    state: .blocked(
                        failure: quarantined.isEmpty ? .fileOperationFailed : failure,
                        quarantineURLs: existing + quarantined
                    )
                )
            }
        }

        let quarantines = existingQuarantineURLs()
        guard quarantines.isEmpty else {
            return ProviderAccountLoadResult(
                registry: nil,
                state: .blocked(
                    failure: .invalidRegistry,
                    quarantineURLs: quarantines
                )
            )
        }

        do {
            let registry = try makeLegacyRegistry()
            try persistValidated(registry)
            return ProviderAccountLoadResult(registry: registry, state: .ready)
        } catch {
            return ProviderAccountLoadResult(
                registry: nil,
                state: .blocked(
                    failure: .fileOperationFailed,
                    quarantineURLs: []
                )
            )
        }
    }

    func loadOrMigrate() throws -> ProviderAccountRegistry {
        let result = loadOrRecover()
        if let registry = result.registry { return registry }
        switch result.state.failure {
        case .unsupportedVersion(let version):
            throw ProviderAccountStoreError.unsupportedVersion(version)
        case .invalidRegistry:
            throw ProviderAccountStoreError.invalidRegistry
        default:
            throw ProviderAccountStoreError.registryUnavailable
        }
    }

    @discardableResult
    func restoreBackup() throws -> ProviderAccountRegistry {
        let loaded = try loadRegistry(at: backupURL).registry
        try persistValidated(loaded)
        return loaded
    }

    @discardableResult
    func resetToLegacy() throws -> ProviderAccountRegistry {
        let registry = try makeLegacyRegistry()
        try persistValidated(registry)
        return registry
    }

    @discardableResult
    func save(_ registry: ProviderAccountRegistry) throws -> ProviderAccountRegistry {
        try validate(registry)
        try persistValidated(registry)
        let persisted = try loadRegistry(at: registryURL).registry
        guard persisted == registry else {
            throw ProviderAccountStoreError.readbackMismatch
        }
        return persisted
    }

    @discardableResult
    func saveDisplayOrder(_ order: [AccountProviderID]) throws -> ProviderAccountRegistry {
        let registry = try loadRegistry(at: registryURL).registry
        let accountIDs = Set(registry.accounts.map(\.id))
        let validOrder = order.filter { accountIDs.contains($0.accountID) }
        let repaired = AccountProviderDisplayOrder.repaired(
            validOrder,
            configured: registry.displayOrder
        )
        return try save(
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

    private struct LoadedRegistry {
        let registry: ProviderAccountRegistry
        let wasMigrated: Bool
    }

    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    private struct VersionOneRegistry: Decodable {
        let version: Int
        let accounts: [ProviderAccount]
        let displayOrder: [AccountProviderID]
        let disconnected: [AccountProviderID]
        let apiKeyReferences: [AccountProviderID]
    }

    private func loadRegistry(at url: URL) throws -> LoadedRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProviderAccountStoreError.invalidRegistry
        }
        let version: Int
        do {
            version = try JSONDecoder().decode(VersionEnvelope.self, from: data).version
        } catch {
            throw ProviderAccountStoreError.invalidRegistry
        }

        let registry: ProviderAccountRegistry
        do {
            switch version {
            case 1:
                let old = try JSONDecoder().decode(VersionOneRegistry.self, from: data)
                registry = ProviderAccountRegistry(
                    version: Self.currentVersion,
                    migrationVersion: Self.currentMigrationVersion,
                    accounts: old.accounts,
                    displayOrder: old.displayOrder,
                    disconnected: old.disconnected,
                    apiKeyReferences: old.apiKeyReferences
                )
            case Self.currentVersion:
                registry = try JSONDecoder().decode(ProviderAccountRegistry.self, from: data)
            default:
                throw ProviderAccountStoreError.unsupportedVersion(version)
            }
        } catch let error as ProviderAccountStoreError {
            throw error
        } catch {
            throw ProviderAccountStoreError.invalidRegistry
        }
        try validate(registry)
        return LoadedRegistry(registry: registry, wasMigrated: version != Self.currentVersion)
    }

    private func makeLegacyRegistry() throws -> ProviderAccountRegistry {
        let rawOrder = defaults.stringArray(forKey: ProviderDisplayOrderStore.defaultsKey) ?? []
        let order = ProviderDisplayOrder.repaired(rawValues: rawOrder).map {
            AccountProviderID(accountID: .legacy, providerID: $0)
        }

        let disconnectedProviders: Set<ProviderID>
        if defaults.object(forKey: ProviderDisconnectionStore.defaultsKey) == nil {
            disconnectedProviders = []
        } else if
            let values = defaults.stringArray(forKey: ProviderDisconnectionStore.defaultsKey),
            let providers = try? strictProviders(values)
        {
            disconnectedProviders = providers
        } else {
            disconnectedProviders = Set(ProviderID.allCases)
        }
        let disconnected = ProviderID.allCases.compactMap { provider in
            disconnectedProviders.contains(provider)
                ? AccountProviderID(accountID: .legacy, providerID: provider)
                : nil
        }
        let apiKeyReferences = try ProviderID.allCases.compactMap {
            try legacyAPIKeyPresence($0)
                ? AccountProviderID(accountID: .legacy, providerID: $0)
                : nil
        }
        return ProviderAccountRegistry(
            version: Self.currentVersion,
            migrationVersion: Self.currentMigrationVersion,
            accounts: [ProviderAccount(id: .legacy, label: AccountLabel.defaultValue)],
            displayOrder: order,
            disconnected: disconnected,
            apiKeyReferences: apiKeyReferences
        )
    }

    private func strictProviders(_ rawValues: [String]) throws -> Set<ProviderID> {
        let providers = rawValues.compactMap(ProviderID.init(rawValue:))
        guard providers.count == rawValues.count,
              Set(providers).count == providers.count
        else {
            throw ProviderAccountStoreError.invalidLegacyState
        }
        return Set(providers)
    }

    private func validate(_ registry: ProviderAccountRegistry) throws {
        guard
            registry.version == Self.currentVersion,
            registry.migrationVersion == Self.currentMigrationVersion,
            !registry.accounts.isEmpty,
            Set(registry.accounts.map(\.id)).count == registry.accounts.count,
            registry.accounts.allSatisfy({ $0.label == AccountLabel.sanitized($0.label) })
        else {
            throw ProviderAccountStoreError.invalidRegistry
        }

        let accountIDs = Set(registry.accounts.map(\.id))
        guard
            accountIDs.contains(.legacy),
            validReferences(registry.displayOrder, accountIDs: accountIDs),
            validReferences(registry.disconnected, accountIDs: accountIDs),
            validReferences(registry.apiKeyReferences, accountIDs: accountIDs),
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

    private func persistValidated(_ registry: ProviderAccountRegistry) throws {
        try validate(registry)
        let data = try encoded(registry)
        try prepareDirectory()
        try write(data, to: registryURL)
        let primary = try loadRegistry(at: registryURL).registry
        guard primary == registry else {
            throw ProviderAccountStoreError.readbackMismatch
        }
        try write(data, to: backupURL)
        let backup = try loadRegistry(at: backupURL).registry
        guard backup == registry else {
            throw ProviderAccountStoreError.readbackMismatch
        }
    }

    private func persistBackup(_ registry: ProviderAccountRegistry) throws {
        try validate(registry)
        try prepareDirectory()
        try write(try encoded(registry), to: backupURL)
    }

    private func encoded(_ registry: ProviderAccountRegistry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(registry)
    }

    private func prepareDirectory() throws {
        try ProviderFileDurability.preparePrivateDirectory(
            registryURL.deletingLastPathComponent()
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try ProviderFileDurability.atomicWrite(
            data,
            to: url,
            permissions: 0o600
        )
    }

    private func quarantine(_ url: URL) throws -> URL {
        let quarantineURL = URL(
            filePath: url.path + ".corrupt-" + UUID().uuidString.lowercased()
        )
        try FileManager.default.moveItem(at: url, to: quarantineURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: quarantineURL.path
        )
        try ProviderFileDurability.syncDirectory(
            quarantineURL.deletingLastPathComponent()
        )
        return quarantineURL
    }

    private func existingQuarantineURLs() -> [URL] {
        let directory = registryURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let primaryPrefix = registryURL.lastPathComponent + ".corrupt-"
        let backupPrefix = backupURL.lastPathComponent + ".corrupt-"
        return names
            .filter { $0.hasPrefix(primaryPrefix) || $0.hasPrefix(backupPrefix) }
            .sorted()
            .map { directory.appending(path: $0) }
    }

    private func recoveryFailure(for error: any Error) -> ProviderAccountRecoveryFailure {
        guard let storeError = error as? ProviderAccountStoreError else {
            return .fileOperationFailed
        }
        if case .unsupportedVersion(let version) = storeError {
            return .unsupportedVersion(version)
        }
        return .invalidRegistry
    }
}
