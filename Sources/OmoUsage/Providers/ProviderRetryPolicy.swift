import Foundation

struct ProviderRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval
    let operationTimeout: TimeInterval
    let maximumResponseBytes: Int

    init(
        maximumAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 8,
        operationTimeout: TimeInterval = 30,
        maximumResponseBytes: Int = 1_048_576
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.operationTimeout = operationTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func backoffDelay(
        afterAttempt attempt: Int,
        randomValue: Double
    ) -> TimeInterval {
        let exponential = min(
            maximumDelay,
            baseDelay * pow(2, Double(attempt - 1))
        )
        return exponential * min(max(randomValue, 0), 1)
    }

    func retryAfterDelay(
        from response: HTTPURLResponse,
        now: Date
    ) -> TimeInterval? {
        guard let value = response.value(
            forHTTPHeaderField: "Retry-After"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        guard let date = Self.httpDateFormatter.date(from: value) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }

    private static var httpDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}
