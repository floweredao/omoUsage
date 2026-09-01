import OmoUsageCore
import Foundation

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
        at now: Date
    ) {
        blockedUntilByAccountProvider[accountProviderID] =
            now.addingTimeInterval(interval)
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
        at now: Date
    ) {
        blockedUntilByAccountProvider[accountProviderID] =
            now.addingTimeInterval(interval)
    }

    func recordSuccess(for accountProviderID: AccountProviderID) {
        blockedUntilByAccountProvider[accountProviderID] = nil
    }
}
