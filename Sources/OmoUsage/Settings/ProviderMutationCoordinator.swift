import CryptoKit
import Darwin
import Foundation

/// Durable checkpoints shared by normal mutations, fault-injection tests, and
/// startup reconciliation. A checkpoint is written and synced before its hook
/// runs, so throwing from the hook models termination at that exact boundary.
enum ProviderMutationPhase: String, Codable, CaseIterable, Sendable {
    case intentSynced
    case secretStaged
    case registryCommitted
    case secretPromotedOrRemoved
    case journalCompleted
}

enum ProviderMutationCoordinatorError: Error, Equatable {
    case registryUnavailable
    case invalidJournal
    case inconsistentJournal
    case keyStoreUnavailable
}

private enum ProviderMutationSecretAction: String, Codable {
    case none
    case write
    case remove
}

private struct ProviderMutationJournal: Codable {
    let version: Int
    let transactionID: UUID
    let oldRegistry: ProviderAccountRegistry
    let newRegistry: ProviderAccountRegistry
    let oldRegistryDigest: String
    let newRegistryDigest: String
    let secretAction: ProviderMutationSecretAction
    let identity: AccountProviderID?
    let secretDigest: String?
    var phase: ProviderMutationPhase
}

struct ProviderMutationCoordinator {
    typealias KeyStore = (ProviderID, AccountID) -> ProviderAPIKeyStore?
    typealias PhaseHook = (ProviderMutationPhase) throws -> Void

    let store: ProviderAccountStore
    let keyStore: KeyStore
    let afterPhase: PhaseHook

    init(
        store: ProviderAccountStore,
        keyStore: @escaping KeyStore = {
            ProviderAPIKeyStore.live(for: $0, accountID: $1)
        },
        afterPhase: @escaping PhaseHook = { _ in }
    ) {
        self.store = store
        self.keyStore = keyStore
        self.afterPhase = afterPhase
    }

    func loadOrRecover() -> ProviderAccountLoadResult {
        do {
            return try withMutationLock { try loadOrRecoverLocked() }
        } catch {
            return ProviderAccountLoadResult(
                registry: nil,
                state: .blocked(
                    failure: .fileOperationFailed,
                    quarantineURLs: store.existingQuarantineURLsForMutation
                )
            )
        }
    }

    @discardableResult
    func restoreBackup() throws -> ProviderAccountRegistry {
        try withMutationLock {
            _ = try loadOrRecoverLocked()
            return try store.restoreBackup()
        }
    }

    @discardableResult
    func resetToLegacy() throws -> ProviderAccountRegistry {
        try withMutationLock {
            if FileManager.default.fileExists(atPath: store.mutationJournalURL.path),
               let journal = try? JSONDecoder().decode(
                   ProviderMutationJournal.self,
                   from: Data(contentsOf: store.mutationJournalURL)
               )
            {
                try removeStagedSecret(journal)
                try ProviderFileDurability.removeIfPresent(store.mutationJournalURL)
            }
            return try store.resetToLegacy()
        }
    }

    @discardableResult
    func mutateRegistry(
        _ transform: (ProviderAccountRegistry) throws -> ProviderAccountRegistry
    ) throws -> ProviderAccountRegistry {
        try withMutationLock {
            let old = try availableRegistryLocked()
            return try performLocked(
                old: old,
                new: transform(old),
                secretAction: .none,
                identity: nil,
                key: nil
            )
        }
    }

    @discardableResult
    func writeSecret(
        identity: AccountProviderID,
        key: String,
        transform: (ProviderAccountRegistry) throws -> ProviderAccountRegistry
    ) throws -> ProviderAccountRegistry {
        try withMutationLock {
            let old = try availableRegistryLocked()
            return try performLocked(
                old: old,
                new: transform(old),
                secretAction: .write,
                identity: identity,
                key: key
            )
        }
    }

    @discardableResult
    func removeSecret(
        identity: AccountProviderID,
        transform: (ProviderAccountRegistry) throws -> ProviderAccountRegistry
    ) throws -> ProviderAccountRegistry {
        try withMutationLock {
            let old = try availableRegistryLocked()
            return try performLocked(
                old: old,
                new: transform(old),
                secretAction: .remove,
                identity: identity,
                key: nil
            )
        }
    }

    @discardableResult
    func addAPIKeyAccount(
        provider: ProviderID,
        accountID: AccountID,
        label: String,
        key: String
    ) throws -> ProviderAccountRegistry {
        let identity = AccountProviderID(accountID: accountID, providerID: provider)
        return try writeSecret(identity: identity, key: key) { registry in
            ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts + [ProviderAccount(id: accountID, label: label)],
                displayOrder: registry.displayOrder + [identity],
                disconnected: registry.disconnected,
                apiKeyReferences: registry.apiKeyReferences + [identity]
            )
        }
    }

    func removeAPIKeyAccount(_ identity: AccountProviderID) throws {
        _ = try removeSecret(identity: identity) { registry in
            let references = registry.apiKeyReferences.filter { $0 != identity }
            let accountStillReferenced = references.contains {
                $0.accountID == identity.accountID
            }
            return ProviderAccountRegistry(
                version: registry.version,
                migrationVersion: registry.migrationVersion,
                accounts: registry.accounts.filter {
                    accountStillReferenced || $0.id != identity.accountID
                },
                displayOrder: registry.displayOrder.filter { $0 != identity },
                disconnected: registry.disconnected.filter { $0 != identity },
                apiKeyReferences: references
            )
        }
    }

    private func availableRegistryLocked() throws -> ProviderAccountRegistry {
        let result = try loadOrRecoverLocked()
        guard let registry = result.registry else {
            throw ProviderMutationCoordinatorError.registryUnavailable
        }
        return registry
    }

    private func loadOrRecoverLocked() throws -> ProviderAccountLoadResult {
        let initial = store.loadOrRecover()
        guard let current = initial.registry else { return initial }
        guard FileManager.default.fileExists(atPath: store.mutationJournalURL.path) else {
            return initial
        }

        let journal: ProviderMutationJournal
        do {
            journal = try JSONDecoder().decode(
                ProviderMutationJournal.self,
                from: Data(contentsOf: store.mutationJournalURL)
            )
        } catch {
            throw ProviderMutationCoordinatorError.invalidJournal
        }
        guard journal.version == 1,
              registryDigest(journal.oldRegistry) == journal.oldRegistryDigest,
              registryDigest(journal.newRegistry) == journal.newRegistryDigest
        else {
            throw ProviderMutationCoordinatorError.invalidJournal
        }

        let currentDigest = registryDigest(current)
        if currentDigest == journal.oldRegistryDigest {
            try removeStagedSecret(journal)
        } else if currentDigest == journal.newRegistryDigest {
            try completeSecretOperation(journal)
        } else {
            throw ProviderMutationCoordinatorError.inconsistentJournal
        }
        try ProviderFileDurability.removeIfPresent(store.mutationJournalURL)
        return store.loadOrRecover()
    }

    private func performLocked(
        old: ProviderAccountRegistry,
        new: ProviderAccountRegistry,
        secretAction: ProviderMutationSecretAction,
        identity: AccountProviderID?,
        key: String?
    ) throws -> ProviderAccountRegistry {
        let transactionID = UUID()
        var journal = ProviderMutationJournal(
            version: 1,
            transactionID: transactionID,
            oldRegistry: old,
            newRegistry: new,
            oldRegistryDigest: registryDigest(old),
            newRegistryDigest: registryDigest(new),
            secretAction: secretAction,
            identity: identity,
            secretDigest: key.map(secretDigest),
            phase: .intentSynced
        )
        try writeJournal(journal)
        try afterPhase(.intentSynced)

        if secretAction == .write {
            guard let identity,
                  let key,
                  let secretStore = keyStore(identity.providerID, identity.accountID)
            else {
                throw ProviderMutationCoordinatorError.keyStoreUnavailable
            }
            try secretStore.stage(key, transactionID: transactionID)
        }
        journal.phase = .secretStaged
        try writeJournal(journal)
        try afterPhase(.secretStaged)

        _ = try store.save(new)
        journal.phase = .registryCommitted
        try writeJournal(journal)
        try afterPhase(.registryCommitted)

        try completeSecretOperation(journal)
        journal.phase = .secretPromotedOrRemoved
        try writeJournal(journal)
        try afterPhase(.secretPromotedOrRemoved)

        journal.phase = .journalCompleted
        try writeJournal(journal)
        try afterPhase(.journalCompleted)
        try ProviderFileDurability.removeIfPresent(store.mutationJournalURL)
        return new
    }

    private func completeSecretOperation(_ journal: ProviderMutationJournal) throws {
        switch journal.secretAction {
        case .none:
            return
        case .write:
            guard let identity = journal.identity,
                  let digest = journal.secretDigest,
                  let secretStore = keyStore(identity.providerID, identity.accountID)
            else {
                throw ProviderMutationCoordinatorError.invalidJournal
            }
            if secretStore.stagedSecretExists(transactionID: journal.transactionID) {
                guard secretStore.stagedSecretDigest(transactionID: journal.transactionID) == digest else {
                    throw ProviderMutationCoordinatorError.inconsistentJournal
                }
                try secretStore.promoteStagedSecret(transactionID: journal.transactionID)
            } else if secretStore.persistedSecretDigest() != digest {
                throw ProviderMutationCoordinatorError.inconsistentJournal
            }
        case .remove:
            guard let identity = journal.identity,
                  let secretStore = keyStore(identity.providerID, identity.accountID)
            else {
                throw ProviderMutationCoordinatorError.invalidJournal
            }
            try secretStore.remove()
        }
    }

    private func removeStagedSecret(_ journal: ProviderMutationJournal) throws {
        guard journal.secretAction == .write else { return }
        guard let identity = journal.identity,
              let secretStore = keyStore(identity.providerID, identity.accountID)
        else {
            throw ProviderMutationCoordinatorError.invalidJournal
        }
        try secretStore.removeStagedSecret(transactionID: journal.transactionID)
    }

    private func writeJournal(_ journal: ProviderMutationJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ProviderFileDurability.atomicWrite(
            try encoder.encode(journal),
            to: store.mutationJournalURL,
            permissions: 0o600
        )
    }

    private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try ProviderFileDurability.preparePrivateDirectory(
            store.registryURL.deletingLastPathComponent()
        )
        let descriptor = open(store.mutationLockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw currentPOSIXError() }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

private func registryDigest(_ registry: ProviderAccountRegistry) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return digest((try? encoder.encode(registry)) ?? Data())
}

private func secretDigest(_ secret: String) -> String {
    digest(Data(secret.utf8))
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum ProviderFileDurability {
    static func preparePrivateDirectory(_ directory: URL) throws {
        let existed = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !existed {
            try syncDirectory(directory.deletingLastPathComponent())
        }
        try syncDirectory(directory)
    }

    static func atomicWrite(
        _ data: Data,
        to url: URL,
        permissions: Int
    ) throws {
        let directory = url.deletingLastPathComponent()
        try preparePrivateDirectory(directory)
        let temporary = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString.lowercased())"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw currentPOSIXError()
        }
        try syncDirectory(directory)
    }

    static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
