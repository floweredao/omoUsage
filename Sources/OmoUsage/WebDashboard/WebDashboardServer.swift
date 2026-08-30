import Foundation
import Network

struct WebDashboardHTTPResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    func serialized() -> Data {
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        let header = (
            ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
                + fields.sorted { $0.key < $1.key }.map {
                    "\($0.key): \($0.value)"
                }
                + ["", ""]
        ).joined(separator: "\r\n")
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

struct WebDashboardSettingsState: Equatable, Codable, Sendable {
    let providerOrder: [String]
    let disconnectedProviders: [String]
    let accountProviderOrder: [AccountProviderID]
    let accountProviderLabels: [String]
    let disconnectedAccountProviders: Set<AccountProviderID>
    let webLanguage: String
    let isRefreshing: Bool
    let refreshRevision: UInt64
}

struct WebDashboardLanguageStore {
    static let key = "OmoUsage.webLanguage"

    private let defaults: UserDefaults
    private let fallback: AppLanguage

    init(
        defaults: UserDefaults,
        fallback: AppLanguage
    ) {
        self.defaults = defaults
        self.fallback = fallback
    }

    func load() -> AppLanguage {
        defaults
            .string(forKey: Self.key)
            .flatMap(AppLanguage.init(rawValue:))
            ?? fallback
    }

    func save(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
    }
}

enum WebDashboardCommand: Equatable, Sendable {
    case refresh
    case setProviderOrder([ProviderID])
    case setProviderVisibility(
        provider: ProviderID,
        isVisible: Bool
    )
    case setAccountProviderOrder([AccountProviderID])
    case setAccountVisibility(
        accountProvider: AccountProviderID,
        isVisible: Bool
    )
    case setWebLanguage(AppLanguage)
}

final class WebDashboardSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var controlState: UsageDashboardControlState
    private var webLanguage: AppLanguage
    private var refreshRevision: UInt64 = 0

    init(
        controlState: UsageDashboardControlState,
        language: AppLanguage
    ) {
        self.controlState = controlState
        self.webLanguage = language
    }

    func update(_ controlState: UsageDashboardControlState) {
        lock.withLock {
            if self.controlState.isRefreshing && !controlState.isRefreshing {
                refreshRevision += 1
            }
            self.controlState = controlState
        }
    }

    func update(webLanguage: AppLanguage) {
        lock.withLock {
            self.webLanguage = webLanguage
        }
    }

    func state() -> WebDashboardSettingsState {
        lock.withLock {
            WebDashboardSettingsState(
                providerOrder: controlState.providerOrder.map(\.rawValue),
                disconnectedProviders: ProviderID.allCases
                    .filter(controlState.disconnectedProviders.contains)
                    .map(\.rawValue),
                accountProviderOrder: controlState.accountProviderOrder,
                accountProviderLabels:
                    controlState.accountProviderOrder.map {
                        controlState.accountProviderLabels[$0]
                            ?? AccountLabel.defaultValue
                    },
                disconnectedAccountProviders:
                    controlState.disconnectedAccountProviders,
                webLanguage: webLanguage.rawValue,
                isRefreshing: controlState.isRefreshing,
                refreshRevision: refreshRevision
            )
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state())
    }
}

final class WebDashboardCommandBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler:
        (@MainActor @Sendable (WebDashboardCommand) -> Void)?

    func install(
        _ handler:
            @escaping @MainActor @Sendable (WebDashboardCommand) -> Void
    ) {
        lock.withLock {
            self.handler = handler
        }
    }

    func send(_ command: WebDashboardCommand) {
        let handler = lock.withLock { self.handler }
        guard let handler else { return }
        Task { @MainActor in
            handler(command)
        }
    }
}

struct WebDashboardHTTPRequest: Sendable {
    static let maximumBytes = 16 * 1_024

    let method: String
    let path: String
    let query: String?
    let headers: [String: String]
    let body: Data

    init(
        method: String,
        path: String,
        query: String? = nil,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.body = body
    }

    static func parse(_ data: Data) -> WebDashboardHTTPRequest? {
        guard data.count <= maximumBytes else { return nil }
        guard
            let headerRange = data.range(
                of: Data("\r\n\r\n".utf8)
            ),
            let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
            )
        else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard
            parts.count == 3,
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                return nil
            }
            headers[name] = value
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard
                let length = Int(rawLength),
                length >= 0
            else {
                return nil
            }
            contentLength = length
        } else {
            contentLength = 0
        }
        let bodyStart = headerRange.upperBound
        guard contentLength <= maximumBytes - bodyStart else {
            return nil
        }
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else {
            return nil
        }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.contains("#") else {
            return nil
        }
        let targetParts = target.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let path = String(targetParts[0])
        let query = targetParts.count == 2 ? String(targetParts[1]) : nil
        return WebDashboardHTTPRequest(
            method: String(parts[0]),
            path: path,
            query: query,
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
    }

    static func expectedLength(_ data: Data) -> Int? {
        guard
            let headerRange = data.range(
                of: Data("\r\n\r\n".utf8)
            ),
            let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
            )
        else {
            return nil
        }
        for line in headerText.components(
            separatedBy: "\r\n"
        ).dropFirst() {
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("content-length:") else {
                continue
            }
            let value = line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else {
                return headerRange.upperBound
            }
            guard length <= maximumBytes - headerRange.upperBound else {
                return maximumBytes + 1
            }
            return headerRange.upperBound + length
        }
        return headerRange.upperBound
    }
}

struct WebDashboardRouter: Sendable {
    private let snapshotData: @Sendable () throws -> Data
    private let settingsData: @Sendable () throws -> Data
    private let indexHTML: Data
    private let appIconSVG: Data
    private let appleTouchIconPNG: Data
    private let providerIconSVGs: [ProviderID: Data]
    private let mutationNonce: String
    private let dispatchCommand:
        @Sendable (WebDashboardCommand) -> Void

    init(
        snapshotData: @escaping @Sendable () throws -> Data,
        settingsData: @escaping @Sendable () throws -> Data = {
            Data("{}".utf8)
        },
        indexHTML: Data,
        appIconSVG: Data = Data(),
        appleTouchIconPNG: Data = WebDashboardAssets.appleTouchIconPNG,
        providerIconSVGs: [ProviderID: Data] =
            WebDashboardAssets.providerIconSVGs,
        mutationNonce: String = "",
        dispatchCommand:
            @escaping @Sendable (WebDashboardCommand) -> Void = { _ in }
    ) {
        self.snapshotData = snapshotData
        self.settingsData = settingsData
        self.indexHTML = indexHTML
        self.appIconSVG = appIconSVG
        self.appleTouchIconPNG = appleTouchIconPNG
        self.providerIconSVGs = providerIconSVGs
        self.mutationNonce = mutationNonce
        self.dispatchCommand = dispatchCommand
    }

    func response(
        method: String,
        path: String
    ) -> WebDashboardHTTPResponse {
        response(
            request: WebDashboardHTTPRequest(
                method: method,
                path: path
            )
        )
    }

    func response(
        request: WebDashboardHTTPRequest
    ) -> WebDashboardHTTPResponse {
        if
            request.method == "GET",
            let provider = providerIconID(from: request.path),
            let icon = providerIconSVGs[provider]
        {
            return response(
                statusCode: 200,
                reasonPhrase: "OK",
                contentType: "image/svg+xml; charset=utf-8",
                body: icon,
                cacheControl: "public, max-age=86400"
            )
        }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/settings"):
            return htmlResponse
        case ("GET", "/api/snapshot"):
            return encodedResponse(
                data: snapshotData,
                unavailableMessage: "Snapshot unavailable\n"
            )
        case ("GET", "/api/settings"):
            return encodedResponse(
                data: settingsData,
                unavailableMessage: "Settings unavailable\n"
            )
        case ("GET", "/favicon.svg"):
            return response(
                statusCode: 200,
                reasonPhrase: "OK",
                contentType: "image/svg+xml; charset=utf-8",
                body: appIconSVG,
                cacheControl: "public, max-age=86400"
            )
        case ("GET", "/apple-touch-icon.png"):
            return response(
                statusCode: 200,
                reasonPhrase: "OK",
                contentType: "image/png",
                body: appleTouchIconPNG,
                cacheControl: "public, max-age=86400"
            )
        case ("POST", "/api/refresh"):
            guard isAuthorized(request) else {
                return forbiddenResponse
            }
            dispatchCommand(.refresh)
            return acceptedResponse
        case ("POST", "/api/settings"):
            guard isAuthorized(request) else {
                return forbiddenResponse
            }
            guard
                request.headers["content-type"]?
                    .lowercased()
                    .hasPrefix("application/json") == true,
                let command = settingsCommand(from: request.body)
            else {
                return badRequestResponse
            }
            dispatchCommand(command)
            return acceptedResponse
        default:
            if let allow = allowedMethods(for: request.path) {
                return response(
                    statusCode: 405,
                    reasonPhrase: "Method Not Allowed",
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Method Not Allowed\n".utf8),
                    extraHeaders: ["Allow": allow]
                )
            }
            return response(
                statusCode: 404,
                reasonPhrase: "Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not Found\n".utf8)
            )
        }
    }

    private var htmlResponse: WebDashboardHTTPResponse {
        response(
            statusCode: 200,
            reasonPhrase: "OK",
            contentType: "text/html; charset=utf-8",
            body: indexHTML,
            extraHeaders: [
                "Content-Security-Policy":
                    "default-src 'self'; "
                    + "connect-src 'self'; "
                    + "img-src 'self' data:; "
                    + "style-src 'unsafe-inline'; "
                    + "script-src 'unsafe-inline'; "
                    + "base-uri 'none'; frame-ancestors 'none'"
            ]
        )
    }

    private var acceptedResponse: WebDashboardHTTPResponse {
        response(
            statusCode: 202,
            reasonPhrase: "Accepted",
            contentType: "application/json; charset=utf-8",
            body: Data(#"{"accepted":true}"#.utf8)
        )
    }

    private var forbiddenResponse: WebDashboardHTTPResponse {
        response(
            statusCode: 403,
            reasonPhrase: "Forbidden",
            contentType: "text/plain; charset=utf-8",
            body: Data("Forbidden\n".utf8)
        )
    }

    private var badRequestResponse: WebDashboardHTTPResponse {
        response(
            statusCode: 400,
            reasonPhrase: "Bad Request",
            contentType: "text/plain; charset=utf-8",
            body: Data("Bad Request\n".utf8)
        )
    }

    private func isAuthorized(
        _ request: WebDashboardHTTPRequest
    ) -> Bool {
        !mutationNonce.isEmpty
            && request.headers["x-omo-csrf"] == mutationNonce
    }

    private func encodedResponse(
        data: @Sendable () throws -> Data,
        unavailableMessage: String
    ) -> WebDashboardHTTPResponse {
        do {
            return response(
                statusCode: 200,
                reasonPhrase: "OK",
                contentType: "application/json; charset=utf-8",
                body: try data()
            )
        } catch {
            return response(
                statusCode: 500,
                reasonPhrase: "Internal Server Error",
                contentType: "text/plain; charset=utf-8",
                body: Data(unavailableMessage.utf8)
            )
        }
    }

    private func settingsCommand(
        from data: Data
    ) -> WebDashboardCommand? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        if Set(dictionary.keys) == ["providerOrder"] {
            guard
                let rawOrder = dictionary["providerOrder"] as? [String],
                rawOrder.count == ProviderID.allCases.count
            else {
                return nil
            }
            let order = rawOrder.compactMap(ProviderID.init(rawValue:))
            guard
                order.count == ProviderID.allCases.count,
                Set(order) == Set(ProviderID.allCases)
            else {
                return nil
            }
            return .setProviderOrder(order)
        }

        if Set(dictionary.keys) == ["accountProviderOrder"] {
            guard
                let rawOrder = dictionary["accountProviderOrder"] as? [Any],
                let roster = configuredAccountRoster(),
                rawOrder.count == roster.count
            else {
                return nil
            }
            let order = rawOrder.compactMap(accountProviderID(from:))
            guard
                order.count == rawOrder.count,
                Set(order).count == order.count,
                Set(order) == roster
            else {
                return nil
            }
            return .setAccountProviderOrder(order)
        }

        if Set(dictionary.keys) == ["accountProvider", "visible"] {
            guard
                let accountProvider = accountProviderID(
                    from: dictionary["accountProvider"]
                ),
                configuredAccountRoster()?.contains(accountProvider) == true,
                let isVisible = jsonBoolean(from: dictionary["visible"])
            else {
                return nil
            }
            return .setAccountVisibility(
                accountProvider: accountProvider,
                isVisible: isVisible
            )
        }

        if Set(dictionary.keys) == ["provider", "visible"] {
            guard
                let rawProvider = dictionary["provider"] as? String,
                let provider = ProviderID(rawValue: rawProvider),
                let isVisible = jsonBoolean(from: dictionary["visible"])
            else {
                return nil
            }
            return .setProviderVisibility(
                provider: provider,
                isVisible: isVisible
            )
        }

        if Set(dictionary.keys) == ["webLanguage"] {
            guard
                let rawLanguage = dictionary["webLanguage"] as? String,
                let language = AppLanguage(rawValue: rawLanguage)
            else {
                return nil
            }
            return .setWebLanguage(language)
        }
        return nil
    }

    private func jsonBoolean(from value: Any?) -> Bool? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private func configuredAccountRoster() -> Set<AccountProviderID>? {
        guard
            let data = try? settingsData(),
            let state = try? JSONDecoder().decode(
                WebDashboardSettingsState.self,
                from: data
            )
        else {
            return nil
        }
        return Set(state.accountProviderOrder)
    }

    private func accountProviderID(from value: Any?) -> AccountProviderID? {
        guard
            let dictionary = value as? [String: Any],
            Set(dictionary.keys) == ["accountID", "providerID"],
            let rawAccountID = dictionary["accountID"] as? String,
            let accountID = AccountID(rawValue: rawAccountID),
            let rawProviderID = dictionary["providerID"] as? String,
            let providerID = ProviderID(rawValue: rawProviderID)
        else {
            return nil
        }
        return AccountProviderID(
            accountID: accountID,
            providerID: providerID
        )
    }

    private func providerIconID(from path: String) -> ProviderID? {
        let prefix = "/provider-icons/"
        let suffix = ".svg"
        guard
            path.hasPrefix(prefix),
            path.hasSuffix(suffix)
        else {
            return nil
        }
        let start = path.index(
            path.startIndex,
            offsetBy: prefix.count
        )
        let end = path.index(
            path.endIndex,
            offsetBy: -suffix.count
        )
        let rawValue = String(path[start..<end])
        guard !rawValue.contains("/") else { return nil }
        return ProviderID(rawValue: rawValue)
    }

    private func allowedMethods(for path: String) -> String? {
        if
            let provider = providerIconID(from: path),
            providerIconSVGs[provider] != nil
        {
            return "GET"
        }
        return switch path {
        case
            "/",
            "/settings",
            "/api/snapshot",
            "/favicon.svg",
            "/apple-touch-icon.png":
            "GET"
        case "/api/settings":
            "GET, POST"
        case "/api/refresh":
            "POST"
        default:
            nil
        }
    }

    private func response(
        statusCode: Int,
        reasonPhrase: String,
        contentType: String,
        body: Data,
        cacheControl: String = "no-store",
        extraHeaders: [String: String] = [:]
    ) -> WebDashboardHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Cache-Control"] = cacheControl
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        return WebDashboardHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            body: body
        )
    }
}

final class WebDashboardSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DashboardSnapshot

    init(_ snapshot: DashboardSnapshot) {
        value = snapshot
    }

    func update(_ snapshot: DashboardSnapshot) {
        lock.withLock {
            value = snapshot
        }
    }

    func snapshot() -> DashboardSnapshot {
        lock.withLock { value }
    }
}

protocol WebDashboardConnection: AnyObject {
    func finish()
}

extension NWConnection: WebDashboardConnection {
    func finish() {
        stateUpdateHandler = nil
        cancel()
    }
}

final class WebDashboardConnectionPool: @unchecked Sendable {
    private let maximumCount: Int
    private let lock = NSLock()
    private var connections: [
        ObjectIdentifier: any WebDashboardConnection
    ] = [:]
    private var isAccepting = false

    init(maximumCount: Int) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
    }

    var count: Int {
        lock.withLock { connections.count }
    }

    func startAccepting() {
        lock.withLock {
            isAccepting = true
        }
    }

    func accept(_ connection: any WebDashboardConnection) -> Bool {
        let accepted = lock.withLock {
            guard
                isAccepting,
                connections.count < maximumCount
            else {
                return false
            }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        if !accepted {
            connection.finish()
        }
        return accepted
    }

    func remove(_ connection: any WebDashboardConnection) {
        _ = lock.withLock {
            connections.removeValue(
                forKey: ObjectIdentifier(connection)
            )
        }
    }

    func stopAcceptingAndFinishAll() {
        let active = lock.withLock {
            isAccepting = false
            let active = Array(connections.values)
            connections.removeAll()
            return active
        }
        active.forEach { $0.finish() }
    }
}

enum WebDashboardListenerState: Sendable {
    case ready
    case failed
}

protocol WebDashboardListening: AnyObject, Sendable {
    func start(
        response: @escaping @Sendable (Data) -> Data,
        stateChanged: @escaping @Sendable (
            WebDashboardListenerState
        ) -> Void
    ) throws
    func stop()
}

final class WebDashboardServer: @unchecked Sendable {
    private enum State {
        case stopped
        case starting
        case running
    }

    private let listener: any WebDashboardListening
    private let gateway: WebDashboardAccessGateway
    private let lock = NSLock()
    private var state = State.stopped

    var isRunning: Bool {
        lock.withLock { state == .running }
    }

    init(
        listener: any WebDashboardListening,
        router: WebDashboardRouter,
        accessStore: WebDashboardAccessStore
    ) {
        self.listener = listener
        self.gateway = WebDashboardAccessGateway(
            accessStore: accessStore,
            router: router
        )
    }

    func start() throws {
        let shouldStart = lock.withLock {
            guard state == .stopped else { return false }
            state = .starting
            return true
        }
        guard shouldStart else { return }

        do {
            try listener.start(
                response: { [gateway] request in
                    Self.responseData(
                        for: request,
                        gateway: gateway
                    )
                },
                stateChanged: { [weak self] listenerState in
                    self?.listenerStateChanged(listenerState)
                }
            )
        } catch {
            lock.withLock {
                state = .stopped
            }
            throw error
        }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard state != .stopped else { return false }
            state = .stopped
            return true
        }
        guard shouldStop else { return }
        listener.stop()
    }

    private func listenerStateChanged(
        _ listenerState: WebDashboardListenerState
    ) {
        switch listenerState {
        case .ready:
            lock.withLock {
                if state == .starting {
                    state = .running
                }
            }
        case .failed:
            let shouldStop = lock.withLock {
                guard state != .stopped else { return false }
                state = .stopped
                return true
            }
            if shouldStop {
                listener.stop()
            }
        }
    }

    private static func responseData(
        for request: Data,
        gateway: WebDashboardAccessGateway
    ) -> Data {
        guard let request = WebDashboardHTTPRequest.parse(request) else {
            return badRequest.serialized()
        }
        return gateway.response(
            request: request
        ).serialized()
    }

    private static let badRequest = WebDashboardHTTPResponse(
        statusCode: 400,
        reasonPhrase: "Bad Request",
        headers: [
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ],
        body: Data("Bad Request\n".utf8)
    )
}

final class NWWebDashboardListener:
    WebDashboardListening,
    @unchecked Sendable
{
    private static let requestTooLarge = WebDashboardHTTPResponse(
        statusCode: 413,
        reasonPhrase: "Payload Too Large",
        headers: [
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ],
        body: Data("Payload Too Large\n".utf8)
    ).serialized()

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(
        label: "com.omo.usage.web-dashboard"
    )
    private let lock = NSLock()
    private let connections = WebDashboardConnectionPool(
        maximumCount: 32
    )
    private var listener: NWListener?

    init(port: UInt16) {
        precondition(
            port > 0,
            "Web dashboard port must be nonzero"
        )
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start(
        response: @escaping @Sendable (Data) -> Data,
        stateChanged: @escaping @Sendable (
            WebDashboardListenerState
        ) -> Void
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                stateChanged(.ready)
            case .failed(let error):
                NSLog(
                    "OmoUsage web dashboard listener failed: %@",
                    String(describing: error)
                )
                let shouldNotify = lock.withLock {
                    guard self.listener === listener else {
                        return false
                    }
                    self.listener = nil
                    return true
                }
                listener.cancel()
                if shouldNotify {
                    connections.stopAcceptingAndFinishAll()
                    stateChanged(.failed)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.finish()
                return
            }
            guard connections.accept(connection) else { return }
            let timeout = DispatchWorkItem { [weak self, weak connection] in
                guard let self, let connection else { return }
                finish(connection)
            }
            queue.asyncAfter(
                deadline: .now() + 10,
                execute: timeout
            )
            connection.stateUpdateHandler = {
                [weak self, weak connection] state in
                guard let connection else { return }
                guard let self else {
                    connection.finish()
                    return
                }
                switch state {
                case .ready:
                    receive(
                        on: connection,
                        accumulated: Data(),
                        response: response
                    )
                case .failed, .cancelled:
                    finish(connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        let inserted = lock.withLock {
            guard self.listener == nil else { return false }
            self.listener = listener
            return true
        }
        guard inserted else {
            listener.cancel()
            return
        }
        connections.startAccepting()
        listener.start(queue: queue)
    }

    func stop() {
        let listener = lock.withLock {
            let listener = self.listener
            self.listener = nil
            return listener
        }
        listener?.cancel()
        connections.stopAcceptingAndFinishAll()
    }

    private func receive(
        on connection: NWConnection,
        accumulated: Data,
        response: @escaping @Sendable (Data) -> Data
    ) {
        let remaining = WebDashboardHTTPRequest.maximumBytes
            - accumulated.count
        guard remaining > 0 else {
            send(Self.requestTooLarge, on: connection)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                if let self {
                    finish(connection)
                } else {
                    connection.finish()
                }
                return
            }
            var request = accumulated
            if let data {
                request.append(data)
            }
            guard request.count <= WebDashboardHTTPRequest.maximumBytes else {
                send(Self.requestTooLarge, on: connection)
                return
            }
            if let expectedLength = WebDashboardHTTPRequest.expectedLength(
                request
            ) {
                guard
                    expectedLength <= WebDashboardHTTPRequest.maximumBytes
                else {
                    send(Self.requestTooLarge, on: connection)
                    return
                }
                guard request.count >= expectedLength else {
                    if isComplete {
                        send(response(request), on: connection)
                    } else {
                        receive(
                            on: connection,
                            accumulated: request,
                            response: response
                        )
                    }
                    return
                }
                send(
                    response(Data(request.prefix(expectedLength))),
                    on: connection
                )
            } else if isComplete {
                send(response(request), on: connection)
            } else {
                receive(
                    on: connection,
                    accumulated: request,
                    response: response
                )
            }
        }
    }

    private func send(
        _ data: Data,
        on connection: NWConnection
    ) {
        connection.send(
            content: data,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                self.finish(connection)
            }
        )
    }

    private func finish(_ connection: NWConnection) {
        connections.remove(connection)
        connection.finish()
    }
}

enum WebDashboardPortPolicy {
    static let productionPort: UInt16 = 7_827

    static func resolve(
        environment: [String: String]
    ) -> UInt16 {
        guard
            environment["OMO_USAGE_FIXTURE_MODE"] == "1",
            let rawValue = environment["OMO_USAGE_WEB_PORT"],
            let port = UInt16(rawValue),
            port > 0
        else {
            return productionPort
        }
        return port
    }
}
