import Foundation
import Observation
import Security

enum WebDashboardAccessMode: Equatable, Sendable {
    case local(port: UInt16)
    case tailscale(host: String, httpsPort: UInt16)

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
        return .tailscale(host: host, httpsPort: 443)
    }

    var bootstrapBaseURL: URL {
        switch self {
        case .local(let port):
            return URL(string: "http://127.0.0.1:\(port)")!
        case .tailscale(let host, let httpsPort):
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            if httpsPort != 443 {
                components.port = Int(httpsPort)
            }
            return components.url!
        }
    }

    func accepts(host: String) -> Bool {
        switch self {
        case .local(let port):
            host == "127.0.0.1:\(port)"
                || host == "localhost:\(port)"
        case .tailscale(let expectedHost, let httpsPort):
            host == Self.authority(
                host: expectedHost,
                httpsPort: httpsPort
            )
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

    static func isValidTailscaleHost(_ host: String) -> Bool {
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

    private static func authority(
        host: String,
        httpsPort: UInt16
    ) -> String {
        httpsPort == 443 ? host : "\(host):\(httpsPort)"
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

    private let lock = NSLock()
    private let tokenGenerator: @Sendable () throws -> String
    private var currentMode: WebDashboardAccessMode
    private var bootstrapToken: String?
    private var sessions: [String] = []
    private let maximumSessionCount = 16

    init(
        mode: WebDashboardAccessMode,
        tokenGenerator: @escaping @Sendable () throws -> String = {
            try WebDashboardAccessStore.secureToken()
        }
    ) {
        currentMode = mode
        self.tokenGenerator = tokenGenerator
    }

    var mode: WebDashboardAccessMode {
        lock.withLock { currentMode }
    }

    func updateMode(_ mode: WebDashboardAccessMode) {
        lock.withLock {
            guard currentMode != mode else { return }
            currentMode = mode
            bootstrapToken = nil
            sessions.removeAll()
        }
    }

    func makeBootstrapURL() throws -> URL {
        let token = "b_\(try tokenGenerator())"
        let mode = lock.withLock {
            bootstrapToken = token
            return currentMode
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
        let session = "s_\(try tokenGenerator())"
        let matched = lock.withLock {
            guard
                let bootstrapToken,
                Self.constantTimeEqual(bootstrapToken, candidate)
            else {
                return false
            }
            self.bootstrapToken = nil
            sessions.append(session)
            if sessions.count > maximumSessionCount {
                sessions.removeFirst(sessions.count - maximumSessionCount)
            }
            return true
        }
        guard matched else { return nil }
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
        let mode = accessStore.mode
        guard let host = request.headers["host"] else {
            return plainResponse(statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard WebDashboardAccessMode.isSyntacticallyValidHost(host) else {
            return plainResponse(statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard mode.accepts(host: host) else {
            return plainResponse(statusCode: 403, reasonPhrase: "Forbidden")
        }

        if request.method == "GET", request.path == "/bootstrap" {
            return bootstrapResponse(for: request, mode: mode)
        }

        guard accessStore.authenticates(
            cookieHeader: request.headers["cookie"]
        ) else {
            return plainResponse(statusCode: 401, reasonPhrase: "Unauthorized")
        }

        if request.method == "POST" {
            guard
                let expectedOrigin = mode.expectedOrigin(for: host),
                request.headers["origin"] == expectedOrigin
            else {
                return plainResponse(statusCode: 403, reasonPhrase: "Forbidden")
            }
        }
        return router.response(request: request)
    }

    private func bootstrapResponse(
        for request: WebDashboardHTTPRequest,
        mode: WebDashboardAccessMode
    ) -> WebDashboardHTTPResponse {
        guard
            let token = bootstrapToken(from: request.query),
            let session = try? accessStore.consumeBootstrapToken(token)
        else {
            return plainResponse(statusCode: 401, reasonPhrase: "Unauthorized")
        }
        let secureAttribute: String
        switch mode {
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

struct TailscaleCommandResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

enum TailscaleDashboardFailure: Error, Equatable, Sendable {
    case commandFailed
    case invalidStatus
    case verificationFailed
}

enum TailscaleDashboardInspection: Equatable, Sendable {
    case unavailable
    case signedOut
    case available(host: String)
    case ready(host: String)
}

protocol TailscaleDashboardServing: Sendable {
    func inspect(
        dashboardPort: UInt16
    ) throws -> TailscaleDashboardInspection
    func enable(dashboardPort: UInt16) throws
    func disable() throws
}

enum TailscaleDashboardServiceFactory {
    static func current(
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) -> any TailscaleDashboardServing {
#if OMO_USAGE_FIXTURES
        if
            environment["OMO_USAGE_FIXTURE_MODE"] == "1",
            let host = environment[
                "OMO_USAGE_TAILSCALE_FIXTURE_HOST"
            ],
            WebDashboardAccessMode.isValidTailscaleHost(host)
        {
            return FixtureTailscaleDashboardService(host: host)
        }
#endif
        return TailscaleCLIService()
    }
}

#if OMO_USAGE_FIXTURES
private struct FixtureTailscaleDashboardService:
    TailscaleDashboardServing
{
    let host: String

    func inspect(
        dashboardPort: UInt16
    ) throws -> TailscaleDashboardInspection {
        .ready(host: host)
    }

    func enable(dashboardPort: UInt16) throws {}
    func disable() throws {}
}
#endif

struct TailscaleCLIService: TailscaleDashboardServing, Sendable {
    static let httpsPort: UInt16 = 8_443

    typealias Execute = @Sendable (
        _ executable: URL,
        _ arguments: [String]
    ) throws -> TailscaleCommandResult

    let executable: URL?
    private let execute: Execute

    init(
        executable: URL? = Self.resolveExecutable(),
        execute: @escaping Execute = Self.executeCommand
    ) {
        self.executable = executable
        self.execute = execute
    }

    func inspect(
        dashboardPort: UInt16
    ) throws -> TailscaleDashboardInspection {
        guard let executable else { return .unavailable }
        let status = try execute(
            executable,
            ["status", "--json", "--peers=false"]
        )
        guard status.status == 0 else { return .signedOut }
        let node = try Self.nodeStatus(status.standardOutput)
        guard
            node.backendState == "Running",
            node.isOnline,
            let host = Self.normalizedHost(node.dnsName)
        else {
            return .signedOut
        }

        let serve = try execute(
            executable,
            ["serve", "status", "--json"]
        )
        guard serve.status == 0 else {
            throw TailscaleDashboardFailure.commandFailed
        }
        return try Self.servesDashboard(
            serve.standardOutput,
            dashboardPort: dashboardPort
        )
            ? .ready(host: host)
            : .available(host: host)
    }

    func enable(dashboardPort: UInt16) throws {
        guard let executable else {
            throw TailscaleDashboardFailure.commandFailed
        }
        let result = try execute(
            executable,
            [
                "serve",
                "--bg",
                "--yes",
                "--https=\(Self.httpsPort)",
                String(dashboardPort)
            ]
        )
        guard result.status == 0 else {
            throw TailscaleDashboardFailure.commandFailed
        }
    }

    func disable() throws {
        guard let executable else {
            throw TailscaleDashboardFailure.commandFailed
        }
        let result = try execute(
            executable,
            [
                "serve",
                "--https=\(Self.httpsPort)",
                "off"
            ]
        )
        guard result.status == 0 else {
            throw TailscaleDashboardFailure.commandFailed
        }
    }

    static func resolveExecutable(
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> URL? {
        let candidates = [
            URL(filePath: "/usr/local/bin/tailscale"),
            URL(filePath: "/opt/homebrew/bin/tailscale")
        ]
        return candidates.first {
            isExecutable($0.path)
        }
    }

    private static func executeCommand(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> TailscaleCommandResult {
        let result = try BoundedProcessRunner().run(
            executable: executable,
            arguments: arguments,
            timeout: 10
        )
        return TailscaleCommandResult(
            status: result.status,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }

    private struct NodeStatus: Decodable {
        struct Node: Decodable {
            let dnsName: String
            let isOnline: Bool

            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
                case isOnline = "Online"
            }
        }

        let backendState: String
        let node: Node?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case node = "Self"
        }

        var dnsName: String? { node?.dnsName }
        var isOnline: Bool { node?.isOnline == true }
    }

    private static func nodeStatus(_ data: Data) throws -> NodeStatus {
        do {
            return try JSONDecoder().decode(NodeStatus.self, from: data)
        } catch {
            throw TailscaleDashboardFailure.invalidStatus
        }
    }

    private static func normalizedHost(_ value: String?) -> String? {
        guard let value else { return nil }
        let host = value.hasSuffix(".")
            ? String(value.dropLast())
            : value
        return WebDashboardAccessMode.isValidTailscaleHost(host)
            ? host
            : nil
    }

    private static func servesDashboard(
        _ data: Data,
        dashboardPort: UInt16
    ) throws -> Bool {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TailscaleDashboardFailure.invalidStatus
        }
        let values = flattenedStrings(object)
        let port = String(Self.httpsPort)
        return values.contains {
            $0 == port || $0.hasSuffix(":\(port)")
        }
            && values.contains(
                "http://127.0.0.1:\(dashboardPort)"
            )
    }

    private static func flattenedStrings(_ value: Any) -> Set<String> {
        if let text = value as? String {
            return [text]
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) {
                result,
                element in
                result.formUnion(flattenedStrings(element.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) {
                $0.formUnion(flattenedStrings($1))
            }
        }
        return []
    }
}

enum TailscaleDashboardState: Equatable, Sendable {
    case checking
    case unavailable
    case signedOut
    case available(host: String)
    case enabling(host: String)
    case ready(host: String)
    case disabling(host: String)
    case failed(TailscaleDashboardFailure)
}

@Observable
@MainActor
final class TailscaleDashboardController {
    private(set) var state: TailscaleDashboardState = .checking

    private let service: any TailscaleDashboardServing
    private let dashboardPort: UInt16
    private let accessStore: WebDashboardAccessStore
    private let statusStore: WebDashboardStatusStore

    init(
        service: any TailscaleDashboardServing,
        dashboardPort: UInt16,
        accessStore: WebDashboardAccessStore,
        statusStore: WebDashboardStatusStore
    ) {
        self.service = service
        self.dashboardPort = dashboardPort
        self.accessStore = accessStore
        self.statusStore = statusStore
    }

    func refresh() async {
        state = .checking
        switch await inspect() {
        case .success(let inspection):
            apply(inspection)
        case .failure(let failure):
            state = .failed(failure)
        }
    }

    func enable() async {
        guard case .available(let host) = state else { return }
        state = .enabling(host: host)
        let service = self.service
        let dashboardPort = self.dashboardPort
        let result = await Task.detached(priority: .utility) {
            do {
                try service.enable(dashboardPort: dashboardPort)
                return Result<TailscaleDashboardInspection,
                    TailscaleDashboardFailure>.success(
                        try service.inspect(
                            dashboardPort: dashboardPort
                        )
                    )
            } catch let failure as TailscaleDashboardFailure {
                return .failure(failure)
            } catch {
                return .failure(.commandFailed)
            }
        }.value
        switch result {
        case .success(.ready(let readyHost)):
            apply(.ready(host: readyHost))
        case .success:
            state = .failed(.verificationFailed)
        case .failure(let failure):
            state = .failed(failure)
        }
    }

    func disable() async {
        guard case .ready(let host) = state else { return }
        state = .disabling(host: host)
        let service = self.service
        let dashboardPort = self.dashboardPort
        let result = await Task.detached(priority: .utility) {
            do {
                try service.disable()
                return Result<TailscaleDashboardInspection,
                    TailscaleDashboardFailure>.success(
                        try service.inspect(
                            dashboardPort: dashboardPort
                        )
                    )
            } catch let failure as TailscaleDashboardFailure {
                return .failure(failure)
            } catch {
                return .failure(.commandFailed)
            }
        }.value
        switch result {
        case .success(let inspection):
            apply(inspection)
        case .failure(let failure):
            state = .failed(failure)
        }
    }

    private func inspect() async -> Result<
        TailscaleDashboardInspection,
        TailscaleDashboardFailure
    > {
        let service = self.service
        let dashboardPort = self.dashboardPort
        return await Task.detached(priority: .utility) {
            do {
                return .success(
                    try service.inspect(dashboardPort: dashboardPort)
                )
            } catch let failure as TailscaleDashboardFailure {
                return .failure(failure)
            } catch {
                return .failure(.commandFailed)
            }
        }.value
    }

    private func apply(_ inspection: TailscaleDashboardInspection) {
        switch inspection {
        case .unavailable:
            publishLocalMode()
            state = .unavailable
        case .signedOut:
            publishLocalMode()
            state = .signedOut
        case .available(let host):
            publishLocalMode()
            state = .available(host: host)
        case .ready(let host):
            let mode = WebDashboardAccessMode.tailscale(
                host: host,
                httpsPort: TailscaleCLIService.httpsPort
            )
            accessStore.updateMode(mode)
            statusStore.publishAccessMode(mode)
            state = .ready(host: host)
        }
    }

    private func publishLocalMode() {
        let mode = WebDashboardAccessMode.local(port: dashboardPort)
        accessStore.updateMode(mode)
        statusStore.publishAccessMode(mode)
    }
}
