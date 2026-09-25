import Foundation

enum ProviderPayload {
    static func object(_ data: Data) throws -> [String: Any] {
        try UsageJSON.object(data)
    }

    static func dictionary(
        _ object: [String: Any],
        _ keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = UsageJSON.object(object[key]) {
                return value
            }
        }
        return nil
    }

    static func value(
        _ object: [String: Any],
        paths: [[String]]
    ) -> Any? {
        for path in paths {
            var current: Any = object
            var found = true
            for key in path {
                guard
                    let dictionary = current as? [String: Any],
                    let next = dictionary[key]
                else {
                    found = false
                    break
                }
                current = next
            }
            if found { return current }
        }
        return nil
    }

    static func number(
        _ object: [String: Any],
        paths: [[String]]
    ) -> Double? {
        UsageJSON.number(value(object, paths: paths))
    }

    static func text(
        _ object: [String: Any],
        paths: [[String]]
    ) -> String? {
        guard let text = value(object, paths: paths) as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(
        _ object: [String: Any],
        paths: [[String]]
    ) -> Date? {
        guard let value = value(object, paths: paths) else { return nil }
        if var seconds = UsageJSON.number(value) {
            if seconds > 10_000_000_000 { seconds /= 1_000 }
            return UsageJSON.date(timeIntervalSince1970: seconds)
        }
        return UsageJSON.date(value)
    }

    static func percent(_ value: Double) -> Int? {
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return Int(exactly: value.rounded())
    }

    static func nonnegativeInteger(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        return Int(exactly: value.rounded(.down))
    }

    static func remainingPercent(
        usedPercent: Double
    ) -> Int? {
        guard usedPercent.isFinite else { return nil }
        return percent(100 - usedPercent)
    }

    static func remainingPercent(
        used: Double,
        limit: Double
    ) -> Int? {
        guard
            used.isFinite,
            limit.isFinite,
            limit > 0,
            (0...limit).contains(used)
        else {
            return nil
        }
        return Int(exactly: (100 - used / limit * 100).rounded())
    }

    static func resetText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        let seconds = max(0, interval)
        let divisor: Double
        let suffix: String
        if seconds < 3_600 {
            divisor = 60
            suffix = "분 후 리셋"
        } else if seconds < 86_400 {
            divisor = 3_600
            suffix = "시간 후 리셋"
        } else {
            divisor = 86_400
            suffix = "일 후 리셋"
        }
        guard let amount = Int(exactly: (seconds / divisor).rounded(.down)) else {
            return nil
        }
        return "\(max(1, amount))\(suffix)"
    }

    /// Like `resetText`, but for deadlines that expire rather than reset —
    /// Claude's reset vouchers and promotional credit buckets end at a fixed
    /// date instead of rolling into a fresh window.
    static func expiryText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        let seconds = max(0, interval)
        let divisor: Double
        let suffix: String
        if seconds < 3_600 {
            divisor = 60
            suffix = "분 후 만료"
        } else if seconds < 86_400 {
            divisor = 3_600
            suffix = "시간 후 만료"
        } else {
            divisor = 86_400
            suffix = "일 후 만료"
        }
        guard let amount = Int(exactly: (seconds / divisor).rounded(.down))
        else {
            return nil
        }
        return "\(max(1, amount))\(suffix)"
    }

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
