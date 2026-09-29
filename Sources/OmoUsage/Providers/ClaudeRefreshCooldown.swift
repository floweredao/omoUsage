import OmoUsageCore
import Foundation

/// Bounds a server `Retry-After` before it becomes a Claude cooldown: short
/// enough values would turn the minute timer into a retry loop, and long
/// ones would hide an account for hours on one bad header.
enum ClaudeRetryAfter {
    static let bounds: ClosedRange<TimeInterval> = 60...1_800

    static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, bounds.lowerBound), bounds.upperBound)
    }
}

/// Rate-limits OAuth refresh attempts after a failure.
///
/// The dashboard refreshes every minute; a token whose refresh keeps failing
/// would otherwise be retried every minute indefinitely, which the Anthropic
/// token endpoint answers with `429 rate_limit_error` for the whole client.
actor ClaudeRefreshCooldown {
    static let shared = ClaudeRefreshCooldown()

    private let interval: TimeInterval
    private var blockedUntilByAccountProvider: [AccountProviderID: Date] = [:]

    init(interval: TimeInterval = 600) {
        self.interval = interval
    }

    func allowsAttempt(
        for accountProviderID: AccountProviderID = AccountProviderID(
            accountID: .legacy,
            providerID: .claude
        ),
        at now: Date
    ) -> Bool {
        guard
            let blockedUntil = blockedUntilByAccountProvider[accountProviderID]
        else {
            return true
        }
        return now >= blockedUntil
    }

    func allowsAttempt(for accountID: AccountID, at now: Date) -> Bool {
        allowsAttempt(
            for: AccountProviderID(
                accountID: accountID,
                providerID: .claude
            ),
            at: now
        )
    }

    func recordFailure(
        for accountProviderID: AccountProviderID = AccountProviderID(
            accountID: .legacy,
            providerID: .claude
        ),
        at now: Date,
        retryAfter: TimeInterval? = nil
    ) {
        // A throttling token endpoint says when to come back; anything else
        // gets the default interval.
        blockedUntilByAccountProvider[accountProviderID] =
            now.addingTimeInterval(
                retryAfter.map(ClaudeRetryAfter.clamped) ?? interval
            )
    }

    func recordFailure(for accountID: AccountID, at now: Date) {
        recordFailure(
            for: AccountProviderID(
                accountID: accountID,
                providerID: .claude
            ),
            at: now
        )
    }

    func recordSuccess(
        for accountProviderID: AccountProviderID = AccountProviderID(
            accountID: .legacy,
            providerID: .claude
        )
    ) {
        blockedUntilByAccountProvider[accountProviderID] = nil
    }

    func recordSuccess(for accountID: AccountID) {
        recordSuccess(
            for: AccountProviderID(
                accountID: accountID,
                providerID: .claude
            )
        )
    }
}

/// Suppresses live usage reads after the usage endpoint answers `429`.
///
/// Deliberately separate state from `ClaudeRefreshCooldown`: a throttled
/// usage read says nothing about the token, and a refusing token endpoint
/// says nothing about usage. Sharing one timer would let either failure
/// silence the other.
actor ClaudeUsageCooldown {
    static let shared = ClaudeUsageCooldown()

    private let interval: TimeInterval
    private var blockedUntilByAccountProvider: [AccountProviderID: Date] = [:]

    init(interval: TimeInterval = 300) {
        self.interval = interval
    }

    func allowsAttempt(
        for accountProviderID: AccountProviderID,
        at now: Date
    ) -> Bool {
        guard
            let blockedUntil = blockedUntilByAccountProvider[accountProviderID]
        else {
            return true
        }
        return now >= blockedUntil
    }

    func recordRateLimit(
        for accountProviderID: AccountProviderID,
        at now: Date,
        retryAfter: TimeInterval? = nil
    ) {
        // Retry-After may only lengthen the usage cooldown: reissuing a
        // throttled read early is what turns a 429 into a longer ban.
        let requested = retryAfter.map(ClaudeRetryAfter.clamped) ?? 0
        blockedUntilByAccountProvider[accountProviderID] =
            now.addingTimeInterval(max(interval, requested))
    }

    func recordSuccess(for accountProviderID: AccountProviderID) {
        blockedUntilByAccountProvider[accountProviderID] = nil
    }
}

/// Runs at most one token exchange per account at a time.
///
/// Claude refresh tokens are single-use: a manual refresh racing the timer
/// would otherwise spend the same grant twice and the loser reads as a
/// revoked login. Concurrent callers join the in-flight exchange, and a
/// caller still holding the grant that was just spent (it read the store
/// before the rotation landed) receives the rotated credential instead of
/// replaying the spent token.
actor ClaudeRefreshCoordinator {
    private struct Rotation {
        let spentRefreshToken: String
        let credential: DiscoveredCredential
    }

    private var flights: [AccountProviderID: Task<DiscoveredCredential, any Error>] = [:]
    private var rotations: [AccountProviderID: Rotation] = [:]

    func refreshed(
        for accountProviderID: AccountProviderID,
        refreshToken: String,
        validAfter deadline: Date,
        exchange: @escaping @Sendable () async throws -> DiscoveredCredential
    ) async throws -> DiscoveredCredential {
        if let flight = flights[accountProviderID] {
            return try await flight.value
        }
        if
            let rotation = rotations[accountProviderID],
            rotation.spentRefreshToken == refreshToken,
            let expiresAt = rotation.credential.expiresAt,
            expiresAt > deadline
        {
            return rotation.credential
        }
        // Unstructured on purpose: a caller cancelled mid-exchange must not
        // abandon a grant the server may already have consumed.
        let task = Task { try await exchange() }
        flights[accountProviderID] = task
        do {
            let credential = try await task.value
            flights[accountProviderID] = nil
            rotations[accountProviderID] = Rotation(
                spentRefreshToken: refreshToken,
                credential: credential
            )
            return credential
        } catch {
            flights[accountProviderID] = nil
            throw error
        }
    }
}
