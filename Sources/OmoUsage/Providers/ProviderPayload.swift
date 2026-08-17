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
            return Date(timeIntervalSince1970: seconds)
        }
        return UsageJSON.date(value)
    }

    static func remainingPercent(
        usedPercent: Double
    ) -> Int {
        Int((100 - usedPercent).rounded())
    }

    static func remainingPercent(
        used: Double,
        limit: Double
    ) -> Int? {
        guard limit > 0 else { return nil }
        return Int((100 - used / limit * 100).rounded())
    }

    static func resetText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 3_600 {
            return "\(max(1, Int(seconds / 60)))분 후 리셋"
        }
        if seconds < 86_400 {
            return "\(max(1, Int(seconds / 3_600)))시간 후 리셋"
        }
        return "\(max(1, Int(seconds / 86_400)))일 후 리셋"
    }

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
