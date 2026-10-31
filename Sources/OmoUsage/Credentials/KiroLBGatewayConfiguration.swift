import Foundation

enum KiroLBGatewayError: Error, Equatable, Sendable {
    case invalidBaseURL
    /// Plain http to a non-loopback host would expose the dashboard password.
    case insecureBaseURL
}

struct KiroLBGatewayConfiguration: Equatable, Sendable {
    static let defaultPort = 8000
    static let environmentFileComponents = [".local", "share", "kiro-lb", ".env"]

    let baseURL: String
    let password: String?

    static func load(
        home: URL,
        environment: [String: String]
    ) -> KiroLBGatewayConfiguration {
        let file = environmentFileComponents.reduce(home) {
            $0.appending(path: $1)
        }
        let values = (try? String(contentsOf: file, encoding: .utf8))
            .map(parseEnvironmentFile) ?? [:]
        let port = values["SERVER_PORT"].flatMap(Int.init)
            .flatMap { (1...65_535).contains($0) ? $0 : nil }
            ?? defaultPort
        let override = environment["KIRO_LB_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return KiroLBGatewayConfiguration(
            baseURL: override.flatMap { $0.isEmpty ? nil : $0 }
                ?? "http://127.0.0.1:\(port)",
            password: values["DASHBOARD_PASSWORD"]
        )
    }

    static func validatedBaseURL(_ value: String) throws -> URL {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: false)?.lowercased(),
            !host.isEmpty
        else {
            throw KiroLBGatewayError.invalidBaseURL
        }
        let loopback: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
        guard scheme == "https" || loopback.contains(host) else {
            throw KiroLBGatewayError.insecureBaseURL
        }
        return url
    }

    /// Minimal dotenv reader: `KEY=value`, optional `export`, single or
    /// double quotes, full-line and unquoted trailing ` #` comments.
    static func parseEnvironmentFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if
                let quote = value.first,
                quote == "\"" || quote == "'",
                let closing = value.dropFirst().firstIndex(of: quote)
            {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}
