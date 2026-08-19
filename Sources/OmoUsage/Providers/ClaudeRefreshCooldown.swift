import Foundation

/// Rate-limits OAuth refresh attempts after a failure.
///
/// The dashboard refreshes every minute; a token whose refresh keeps failing
/// would otherwise be retried every minute indefinitely, which the Anthropic
/// token endpoint answers with `429 rate_limit_error` for the whole client.
actor ClaudeRefreshCooldown {
    static let shared = ClaudeRefreshCooldown()

    private let interval: TimeInterval
    private var blockedUntil: Date?

    init(interval: TimeInterval = 600) {
        self.interval = interval
    }

    func allowsAttempt(at now: Date) -> Bool {
        guard let blockedUntil else { return true }
        return now >= blockedUntil
    }

    func recordFailure(at now: Date) {
        blockedUntil = now.addingTimeInterval(interval)
    }

    func recordSuccess() {
        blockedUntil = nil
    }
}
