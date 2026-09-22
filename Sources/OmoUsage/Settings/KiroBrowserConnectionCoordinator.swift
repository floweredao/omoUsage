import Foundation
import Observation
import OmoUsageCore

enum KiroBrowserConnectionTarget: Equatable {
    case existing(AccountProviderID)
    case newAccount(String)
}

enum KiroBrowserConnectionError: Error, Equatable {
    case alreadyConnecting
    case usageUnavailable
    case accountMismatch
}

@MainActor
@Observable
final class KiroBrowserConnectionCoordinator {
    private(set) var pending: KiroBrowserConnectionTarget?

    func connect(
        target: KiroBrowserConnectionTarget,
        expectedProfile: String? = nil,
        excludedProfiles: Set<String> = [],
        discover: () throws -> CredentialSnapshot,
        authenticate: () async throws -> CredentialSnapshot,
        validate: (CredentialSnapshot) async throws -> ProviderUsage,
        persist: (KiroBrowserConnectionTarget, CredentialSnapshot) throws -> AccountProviderID
    ) async throws -> AccountProviderID {
        guard pending == nil else { throw KiroBrowserConnectionError.alreadyConnecting }
        pending = target
        defer { pending = nil }
        try Task.checkCancellation()

        func matches(_ snapshot: CredentialSnapshot) -> Bool {
            guard snapshot.provider == .kiro, let profile = snapshot.accountReference else { return false }
            return (expectedProfile == nil || expectedProfile == profile)
                && !excludedProfiles.contains(profile)
        }

        var candidate: CredentialSnapshot?
        do {
            let existing = try discover()
            if matches(existing) { candidate = existing }
        } catch CredentialDiscoveryError.notFound(.kiro) {
            candidate = nil
        } catch CredentialDiscoveryError.expired(.kiro) {
            candidate = nil
        }

        if let existing = candidate {
            do {
                let usage = try await validate(existing)
                try Task.checkCancellation()
                guard usage.provider == .kiro, usage.availability == .available else {
                    throw KiroBrowserConnectionError.usageUnavailable
                }
            } catch ProviderTransportError.authenticationRequired(.kiro) {
                candidate = nil
            } catch CredentialDiscoveryError.expired(.kiro) {
                candidate = nil
            }
        }
        if candidate == nil {
            try Task.checkCancellation()
            let authenticated = try await authenticate()
            try Task.checkCancellation()
            guard matches(authenticated) else { throw KiroBrowserConnectionError.accountMismatch }
            let usage = try await validate(authenticated)
            try Task.checkCancellation()
            guard usage.provider == .kiro, usage.availability == .available else {
                throw KiroBrowserConnectionError.usageUnavailable
            }
            candidate = authenticated
        }
        guard let candidate else { throw KiroBrowserConnectionError.usageUnavailable }
        try Task.checkCancellation()
        return try persist(target, candidate)
    }
}
