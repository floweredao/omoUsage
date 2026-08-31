import Foundation
import Security

enum WebDashboardAccessMode: Equatable, Sendable {
    case local(port: UInt16)
    case tailscale(host: String)

    static func resolve(
        environment: [String: String],
        port: UInt16
    ) -> WebDashboardAccessMode {
        guard
            let host = environment["OMO_USAGE_WEB_TAILSCALE_HOST"],
            isValidTailscaleHost(host)
        else {
            return .local(port: port)
        }
        return .tailscale(host: host)
    }

    var bootstrapBaseURL: URL {
        switch self {
        case .local(let port):
            URL(string: "http://127.0.0.1:\(port)")!
        case .tailscale(let host):
            URL(string: "https://\(host)")!
        }
    }

    func accepts(host: String) -> Bool {
        switch self {
        case .local(let port):
            host == "127.0.0.1:\(port)"
                || host == "localhost:\(port)"
        case .tailscale(let expectedHost):
            host == expectedHost
        }
    }

    func expectedOrigin(for host: String) -> String? {
        guard accepts(host: host) else { return nil }
        return switch self {
        case .local:
            "http://\(host)"
        case .tailscale:
            "https://\(host)"
        }
    }

    static func isSyntacticallyValidHost(_ host: String) -> Bool {
        guard
            !host.isEmpty,
            host.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
            !host.contains(","),
            !host.contains("/"),
            !host.contains("\\"),
            !host.contains("@"),
            !host.contains("#"),
            !host.contains("?")
        else {
            return false
        }
        return true
    }

    private static func isValidTailscaleHost(_ host: String) -> Bool {
        guard
            isSyntacticallyValidHost(host),
            host == host.lowercased(),
            host.hasSuffix(".ts.net"),
            !host.contains(":")
        else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4 else { return false }
        return labels.allSatisfy { label in
            guard
                !label.isEmpty,
                label.count <= 63,
                label.first != "-",
                label.last != "-"
            else {
                return false
            }
            return label.utf8.allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7a)
                    || ($0 >= 0x30 && $0 <= 0x39)
                    || $0 == 0x2d
            }
        }
    }
}

enum WebDashboardAccessError: Error {
    case randomGenerationFailed
    case invalidBootstrapURL
}

enum FixtureWebBootstrapExporter {
    static func exportIfRequested(
        accessStore: WebDashboardAccessStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        guard
            environment["OMO_USAGE_FIXTURE_MODE"] == "1",
            let path = environment["OMO_USAGE_BOOTSTRAP_URL_FILE"],
            !path.isEmpty
        else {
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        let value = try accessStore.makeBootstrapURL().absoluteString + "\n"
        try Data(value.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

final class WebDashboardAccessStore: @unchecked Sendable {
    static let sessionCookieName = "omo_session"

    let mode: WebDashboardAccessMode

    private let lock = NSLock()
    private let tokenGenerator: @Sendable () throws -> String
    private var bootstrapToken: String?
    private var sessions: [String] = []
    private let maximumSessionCount = 16

    init(
        mode: WebDashboardAccessMode,
        tokenGenerator: @escaping @Sendable () throws -> String = {
            try WebDashboardAccessStore.secureToken()
        }
    ) {
        self.mode = mode
        self.tokenGenerator = tokenGenerator
    }

    func makeBootstrapURL() throws -> URL {
        let token = "b_\(try tokenGenerator())"
        lock.withLock {
            bootstrapToken = token
        }
        guard var components = URLComponents(
            url: mode.bootstrapBaseURL.appending(path: "bootstrap"),
            resolvingAgainstBaseURL: false
        ) else {
            throw WebDashboardAccessError.invalidBootstrapURL
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw WebDashboardAccessError.invalidBootstrapURL
        }
        return url
    }

    func consumeBootstrapToken(_ candidate: String) throws -> String? {
        let matched = lock.withLock {
            guard
                let bootstrapToken,
                Self.constantTimeEqual(bootstrapToken, candidate)
            else {
                return false
            }
            self.bootstrapToken = nil
            return true
        }
        guard matched else { return nil }

        let session = "s_\(try tokenGenerator())"
        lock.withLock {
            sessions.append(session)
            if sessions.count > maximumSessionCount {
                sessions.removeFirst(sessions.count - maximumSessionCount)
            }
        }
        return session
    }

    func authenticates(cookieHeader: String?) -> Bool {
        guard let candidate = Self.sessionToken(from: cookieHeader) else {
            return false
        }
        return lock.withLock {
            sessions.contains {
                Self.constantTimeEqual($0, candidate)
            }
        }
    }

    private static func sessionToken(from header: String?) -> String? {
        guard let header else { return nil }
        let matches = header.split(separator: ";").compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard
                parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces)
                    == sessionCookieName
            else {
                return nil
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard matches.count == 1, !matches[0].isEmpty else { return nil }
        return matches[0]
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func secureToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WebDashboardAccessError.randomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct WebDashboardAccessGateway: Sendable {
    private let accessStore: WebDashboardAccessStore
    private let router: WebDashboardRouter

    init(
        accessStore: WebDashboardAccessStore,
        router: WebDashboardRouter
    ) {
        self.accessStore = accessStore
        self.router = router
    }

    func response(
        request: WebDashboardHTTPRequest
    ) -> WebDashboardHTTPResponse {
        guard let host = request.headers["host"] else {
            return plainResponse(statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard WebDashboardAccessMode.isSyntacticallyValidHost(host) else {
            return plainResponse(statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard accessStore.mode.accepts(host: host) else {
            return plainResponse(statusCode: 403, reasonPhrase: "Forbidden")
        }

        if request.method == "GET", request.path == "/bootstrap" {
            return bootstrapResponse(for: request)
        }

        guard accessStore.authenticates(
            cookieHeader: request.headers["cookie"]
        ) else {
            return plainResponse(statusCode: 401, reasonPhrase: "Unauthorized")
        }

        if request.method == "POST" {
            guard
                let expectedOrigin = accessStore.mode.expectedOrigin(for: host),
                request.headers["origin"] == expectedOrigin
            else {
                return plainResponse(statusCode: 403, reasonPhrase: "Forbidden")
            }
        }
        return router.response(request: request)
    }

    private func bootstrapResponse(
        for request: WebDashboardHTTPRequest
    ) -> WebDashboardHTTPResponse {
        guard
            let token = bootstrapToken(from: request.query),
            let session = try? accessStore.consumeBootstrapToken(token)
        else {
            return plainResponse(statusCode: 401, reasonPhrase: "Unauthorized")
        }
        let secureAttribute: String
        switch accessStore.mode {
        case .local:
            secureAttribute = ""
        case .tailscale:
            secureAttribute = "; Secure"
        }
        return WebDashboardHTTPResponse(
            statusCode: 303,
            reasonPhrase: "See Other",
            headers: securityHeaders.merging([
                "Cache-Control": "no-store",
                "Location": "/",
                "Set-Cookie":
                    "\(WebDashboardAccessStore.sessionCookieName)=\(session); "
                    + "HttpOnly; SameSite=Strict; Path=/"
                    + secureAttribute
            ], uniquingKeysWith: { _, new in new }),
            body: Data()
        )
    }

    private func bootstrapToken(from query: String?) -> String? {
        guard
            let query,
            !query.isEmpty,
            let components = URLComponents(string: "http://fixture/?\(query)"),
            let items = components.queryItems,
            items.count == 1,
            items[0].name == "token",
            let token = items[0].value,
            token.utf8.allSatisfy({
                ($0 >= 0x41 && $0 <= 0x5a)
                    || ($0 >= 0x61 && $0 <= 0x7a)
                    || ($0 >= 0x30 && $0 <= 0x39)
                    || $0 == 0x2d
                    || $0 == 0x5f
            })
        else {
            return nil
        }
        return token
    }

    private func plainResponse(
        statusCode: Int,
        reasonPhrase: String
    ) -> WebDashboardHTTPResponse {
        WebDashboardHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: securityHeaders.merging([
                "Cache-Control": "no-store",
                "Content-Type": "text/plain; charset=utf-8"
            ], uniquingKeysWith: { _, new in new }),
            body: Data("\(reasonPhrase)\n".utf8)
        )
    }

    private var securityHeaders: [String: String] {
        [
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff"
        ]
    }
}
