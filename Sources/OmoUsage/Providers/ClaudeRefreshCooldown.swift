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

    /// Returns when the next live read is allowed.
    @discardableResult
    func recordRateLimit(
        for accountProviderID: AccountProviderID,
        at now: Date,
        retryAfter: TimeInterval? = nil
    ) -> Date {
        // Retry-After may only lengthen the usage cooldown: reissuing a
        // throttled read early is what turns a 429 into a longer ban.
        let requested = retryAfter.map(ClaudeRetryAfter.clamped) ?? 0
        let blockedUntil = now.addingTimeInterval(max(interval, requested))
        blockedUntilByAccountProvider[accountProviderID] = blockedUntil
        return blockedUntil
    }

    func recordSuccess(for accountProviderID: AccountProviderID) {
        blockedUntilByAccountProvider[accountProviderID] = nil
    }
}

/// Reuses each account's last successful usage read for `interval`.
///
/// The usage endpoint is undocumented and every program reading the same
/// account spends one budget; reading it on every one-minute dashboard tick
/// is what drew the 429s. An account's first reuse window is lengthened by
/// its own offset so several accounts never come due on the same tick.
actor ClaudeUsageCache {
    static let shared = ClaudeUsageCache()
    /// The dashboard timer fires a moment early or late; a read due within
    /// this slack counts as due, so the period stays five minutes, not six.
    static let dueSlack: TimeInterval = 5

    private struct Entry {
        let usage: ProviderUsage
        let recordedAt: Date
        let validUntil: Date
    }

    private let interval: TimeInterval
    private let staggerStep: TimeInterval
    private var entries: [AccountProviderID: Entry] = [:]
    private var phases: [AccountProviderID: Int] = [:]

    init(interval: TimeInterval = 300, staggerStep: TimeInterval = 120) {
        self.interval = interval
        self.staggerStep = staggerStep
    }

    func usage(
        for accountProviderID: AccountProviderID,
        at now: Date
    ) -> ProviderUsage? {
        guard
            let entry = entries[accountProviderID],
            now >= entry.recordedAt,
            now.addingTimeInterval(Self.dueSlack) < entry.validUntil
        else {
            return nil
        }
        return entry.usage
    }

    func record(
        _ usage: ProviderUsage,
        for accountProviderID: AccountProviderID,
        at now: Date
    ) {
        var window = interval
        if phases[accountProviderID] == nil {
            let phase = phases.count
            phases[accountProviderID] = phase
            if interval > 0 {
                window += (Double(phase) * staggerStep)
                    .truncatingRemainder(dividingBy: interval)
            }
        }
        entries[accountProviderID] = Entry(
            usage: usage,
            recordedAt: now,
            validUntil: now.addingTimeInterval(window)
        )
    }
}

/// Publishes each Claude account's latest usage read and rate-limit wait to
/// a private local file, so local tools (ddolmeng's quota watch) can reuse
/// it instead of spending the same account's budget. Never holds a token.
///
/// Format (`schema_version` 1): `written_at` and an `accounts` array of
/// `account_id`, `account_label`, `fetched_at`, `five_hour` and `seven_day`
/// (`utilization`, `resets_at` as the API sent them) and
/// `rate_limited_until`. Times are ISO 8601 UTC; absent facts are `null`.
actor ClaudeUsageShareStore {
    static let live = ClaudeUsageShareStore(
        url: FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Application Support/OmoUsage/claude-usage.json"
        )
    )

    private struct Window {
        let utilization: Double
        let resetsAt: String?
    }

    private struct Entry {
        var label: String
        var fetchedAt: Date?
        var fiveHour: Window?
        var sevenDay: Window?
        var rateLimitedUntil: Date?
    }

    let url: URL
    private var entries: [AccountID: Entry] = [:]

    init(url: URL) {
        self.url = url
    }

    func recordSuccess(
        _ data: Data,
        for accountID: AccountID,
        label: String,
        at now: Date
    ) {
        let object = try? UsageJSON.object(data)
        entries[accountID] = Entry(
            label: AccountLabel.sanitized(label),
            fetchedAt: now,
            fiveHour: Self.window(object?["five_hour"]),
            sevenDay: Self.window(object?["seven_day"]),
            rateLimitedUntil: nil
        )
        write(at: now)
    }

    func recordRateLimit(
        until blockedUntil: Date,
        for accountID: AccountID,
        label: String,
        at now: Date
    ) {
        var entry = entries[accountID] ?? Entry(label: label)
        entry.label = AccountLabel.sanitized(label)
        entry.rateLimitedUntil = blockedUntil
        entries[accountID] = entry
        write(at: now)
    }

    private static func window(_ value: Any?) -> Window? {
        guard
            let object = UsageJSON.object(value),
            let utilization = UsageJSON.number(object["utilization"]),
            utilization.isFinite
        else {
            return nil
        }
        return Window(
            utilization: utilization,
            resetsAt: object["resets_at"] as? String
        )
    }

    private func write(at now: Date) {
        func time(_ date: Date?) -> Any {
            date.map { $0.formatted(.iso8601) } ?? NSNull()
        }
        func window(_ window: Window?) -> Any {
            guard let window else { return NSNull() }
            return [
                "utilization": window.utilization,
                "resets_at": window.resetsAt ?? NSNull()
            ] as [String: Any]
        }
        let accounts = entries
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { accountID, entry -> [String: Any] in
                [
                    "account_id": accountID.rawValue,
                    "account_label": entry.label,
                    "fetched_at": time(entry.fetchedAt),
                    "five_hour": window(entry.fiveHour),
                    "seven_day": window(entry.sevenDay),
                    "rate_limited_until": time(entry.rateLimitedUntil)
                ]
            }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "schema_version": 1,
                    "written_at": now.formatted(.iso8601),
                    "accounts": accounts
                ] as [String: Any],
                options: [.prettyPrinted, .sortedKeys]
            )
            try ProviderFileDurability.atomicWrite(
                data,
                to: url,
                permissions: 0o600
            )
        } catch {
            // Sharing is best effort: the dashboard keeps its own values.
            DiagnosticStore.shared.record(
                error: error,
                provider: .claude,
                category: .providerRefresh
            )
        }
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
