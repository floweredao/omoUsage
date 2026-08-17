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
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        if let date = try? Date(text, strategy: .iso8601) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.date(from: text)
    }
}
