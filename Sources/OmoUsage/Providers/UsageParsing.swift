import Foundation
import CoreFoundation

enum UsageParsingError: Error, Equatable {
    case invalidPayload
}

enum UsageJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            throw UsageParsingError.invalidPayload
        }
        return object
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    static func number(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            result = number.doubleValue
        case let string as String:
            result = Double(string)
        default:
            return nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let parsed: Date?
        if let date = try? Date(text, strategy: .iso8601) {
            parsed = date
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]
            parsed = formatter.date(from: text)
        }
        guard
            let parsed,
            date(timeIntervalSince1970: parsed.timeIntervalSince1970) != nil
        else {
            return nil
        }
        return parsed
    }

    static func date(timeIntervalSince1970 seconds: Double) -> Date? {
        let earliest = Date.distantPast.timeIntervalSince1970
        let latest = Date.distantFuture.timeIntervalSince1970
        guard seconds.isFinite, (earliest...latest).contains(seconds) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
