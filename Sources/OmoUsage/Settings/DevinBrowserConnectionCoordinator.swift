import Foundation
import Observation
import OmoUsageCore

enum DevinBrowserConnectionTarget: Equatable {
    case existing(AccountProviderID)
    case newAccount(String)
}

enum DevinBrowserConnectionError: Error, Equatable {
    case alreadyConnecting
    case usageUnavailable
}

@MainActor
@Observable
final class DevinBrowserConnectionCoordinator {
    private(set) var pending: DevinBrowserConnectionTarget?

    func connect(
        target: DevinBrowserConnectionTarget,
        authenticate: () async throws -> CredentialSnapshot,
        validate: (CredentialSnapshot) async throws -> ProviderUsage,
        persist: (DevinBrowserConnectionTarget, CredentialSnapshot) throws -> AccountProviderID
    ) async throws -> AccountProviderID {
        guard pending == nil else { throw DevinBrowserConnectionError.alreadyConnecting }
        if case .newAccount(let label) = target {
            _ = try ProviderAccountRegistryController.validatedAccountLabel(label)
        }
        try Task.checkCancellation()
        pending = target
        defer { pending = nil }
        let snapshot = try await authenticate()
        try Task.checkCancellation()
        let usage = try await validate(snapshot)
        try Task.checkCancellation()
        guard snapshot.provider == .devin,
              usage.provider == .devin,
              usage.availability == .available
        else {
            throw DevinBrowserConnectionError.usageUnavailable
        }
        return try persist(target, snapshot)
    }
}
