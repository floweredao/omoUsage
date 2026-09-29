import AppKit
import Foundation
import Observation
import OmoUsageCore

enum ClaudeBrowserConnectionTarget: Equatable, Sendable {
    /// Reconnects an account the registry already knows, including `.legacy`.
    case existing(AccountID)
    /// Creates a new Claude account with this label once sign-in succeeds.
    case newAccount(label: String)
}

enum ClaudeBrowserConnectionError: Error, Equatable {
    case alreadyConnecting
    case cancelled
    case timedOut
    case stateMismatch
    case authorizationFailed
    case exchangeFailed
    case storageFailed
}

/// Signs a Claude account in through the in-app browser flow and stores the
/// grant as that account's app-owned snapshot (`claude/<account>`). Neither
/// the Claude CLI nor any `Claude Code-credentials*` Keychain item is used.
@MainActor
@Observable
final class ClaudeBrowserConnectionCoordinator {
    typealias Authenticate = @MainActor () async throws -> CredentialSnapshot
    /// Commits a new registry account whose secret is `encodedSecret`,
    /// e.g. `ProviderAccountRegistryController.addCapturedCompanionAccount`.
    typealias RegisterAccount = @MainActor (_ label: String, _ encodedSecret: String) throws -> AccountID

    private(set) var pending: ClaudeBrowserConnectionTarget?
    @ObservationIgnored private let snapshotStore: ProviderCredentialSnapshotStore
    @ObservationIgnored private let authenticate: Authenticate
    @ObservationIgnored private let registerAccount: RegisterAccount

    init(
        snapshotStore: ProviderCredentialSnapshotStore,
        authenticate: Authenticate? = nil,
        registerAccount: @escaping RegisterAccount
    ) {
        self.snapshotStore = snapshotStore
        self.authenticate = authenticate ?? {
            try await ClaudeBrowserAuthenticationClient().authenticate {
                NSWorkspace.shared.open($0)
            }
        }
        self.registerAccount = registerAccount
    }

    @discardableResult
    func connect(target: ClaudeBrowserConnectionTarget) async throws -> AccountID {
        guard pending == nil else { throw ClaudeBrowserConnectionError.alreadyConnecting }
        var label: String?
        if case .newAccount(let rawLabel) = target {
            label = try ProviderAccountRegistryController.validatedAccountLabel(rawLabel)
        }
        guard !Task.isCancelled else { throw ClaudeBrowserConnectionError.cancelled }
        pending = target
        defer { pending = nil }
        let snapshot: CredentialSnapshot
        do {
            snapshot = try await authenticate()
        } catch {
            throw Self.connectionError(error)
        }
        guard !Task.isCancelled else { throw ClaudeBrowserConnectionError.cancelled }
        guard snapshot.provider == .claude else { throw ClaudeBrowserConnectionError.exchangeFailed }
        switch target {
        case .existing(let accountID):
            do {
                try snapshotStore.save(
                    snapshot,
                    for: AccountProviderID(accountID: accountID, providerID: .claude)
                )
            } catch {
                throw ClaudeBrowserConnectionError.storageFailed
            }
            return accountID
        case .newAccount:
            let secret: String
            do { secret = try snapshot.encodedSecret() }
            catch { throw ClaudeBrowserConnectionError.storageFailed }
            do {
                return try registerAccount(label ?? "", secret)
            } catch ProviderAccountRegistryControllerError.invalidLabel {
                throw ProviderAccountRegistryControllerError.invalidLabel
            } catch {
                throw ClaudeBrowserConnectionError.storageFailed
            }
        }
    }

    private static func connectionError(_ error: Error) -> ClaudeBrowserConnectionError {
        if error is CancellationError { return .cancelled }
        switch error as? ClaudeBrowserAuthenticationError {
        case .timedOut: return .timedOut
        case .stateMismatch: return .stateMismatch
        case .exchangeFailed, .invalidToken: return .exchangeFailed
        case .browserOpenFailed, .listenerFailed, .authorizationDenied,
             .randomGenerationFailed, nil:
            return .authorizationFailed
        }
    }
}
