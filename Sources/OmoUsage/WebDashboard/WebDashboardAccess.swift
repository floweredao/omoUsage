import AppKit
import Foundation
import Observation

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

    var dashboardURL: URL {
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

enum FixtureWebDashboardURLExporter {
    static func exportIfRequested(
        accessStore: WebDashboardAccessStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        guard
            environment["OMO_USAGE_FIXTURE_MODE"] == "1",
            let path = environment["OMO_USAGE_DASHBOARD_URL_FILE"],
            !path.isEmpty
        else {
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        let value = accessStore.dashboardURL.absoluteString + "\n"
        try Data(value.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

final class WebDashboardAccessStore: @unchecked Sendable {
    private let lock = NSLock()
    private var currentMode: WebDashboardAccessMode

    init(mode: WebDashboardAccessMode) {
        currentMode = mode
    }

    var mode: WebDashboardAccessMode {
        lock.withLock { currentMode }
    }

    var dashboardURL: URL {
        lock.withLock { currentMode.dashboardURL }
    }

    func updateMode(_ mode: WebDashboardAccessMode) {
        lock.withLock {
            guard currentMode != mode else { return }
            currentMode = mode
        }
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
    case timedOut
    case offline
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
        try Task.checkCancellation()
        guard let executable else { return .unavailable }
        let status = try execute(
            executable,
            ["status", "--json", "--peers=false"]
        )
        try Task.checkCancellation()
        guard status.status == 0 else {
            throw TailscaleDashboardFailure.commandFailed
        }
        let node = try Self.nodeStatus(status.standardOutput)
        if ["NeedsLogin", "NeedsMachineAuth"].contains(node.backendState) {
            return .signedOut
        }
        guard
            node.backendState == "Running",
            node.isOnline
        else {
            throw TailscaleDashboardFailure.offline
        }
        guard let host = Self.normalizedHost(node.dnsName) else {
            throw TailscaleDashboardFailure.invalidStatus
        }

        try Task.checkCancellation()
        let serve = try execute(
            executable,
            ["serve", "status", "--json"]
        )
        try Task.checkCancellation()
        guard serve.status == 0 else {
            throw TailscaleDashboardFailure.commandFailed
        }
        return try Self.servesDashboard(
            serve.standardOutput,
            host: host,
            dashboardPort: dashboardPort
        )
            ? .ready(host: host)
            : .available(host: host)
    }

    func enable(dashboardPort: UInt16) throws {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        host: String,
        dashboardPort: UInt16
    ) throws -> Bool {
        let configuration: ServeConfiguration
        do {
            configuration = try JSONDecoder().decode(
                ServeConfiguration.self,
                from: data
            )
        } catch {
            throw TailscaleDashboardFailure.invalidStatus
        }
        let port = String(Self.httpsPort)
        let authority = "\(host):\(port)"
        return configuration.TCP?[port]?.HTTPS == true
            && configuration.Web?[authority]?.Handlers?["/"]?.Proxy
                == "http://127.0.0.1:\(dashboardPort)"
            && configuration.AllowFunnel?[authority] != true
    }

    private struct ServeConfiguration: Decodable {
        struct TCPHandler: Decodable {
            let HTTPS: Bool?
        }

        struct WebHandler: Decodable {
            struct Handler: Decodable {
                let Proxy: String?
            }

            let Handlers: [String: Handler]?
        }

        let TCP: [String: TCPHandler]?
        let Web: [String: WebHandler]?
        let AllowFunnel: [String: Bool]?
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
    private let diagnostics: DiagnosticStore
    private let retryWait: @Sendable (Duration) async throws -> Void
    private var monitoringTask: Task<Void, Never>?
    private var monitoringID: UUID?
    private var monitoringEnabled = false
    private var stopped = false
    private var wakeObserver: (NotificationCenter, NSObjectProtocol)?
    private var revision = 0
    private var lastDiagnosticState: TailscaleDashboardState?

    private enum Action {
        case inspect
        case enable
        case disable
    }

    private struct Operation {
        let id: UUID
        let action: Action
        let revision: Int
        let task: Task<
            Result<TailscaleDashboardInspection, TailscaleDashboardFailure>,
            Never
        >
    }

    private var operation: Operation?

    init(
        service: any TailscaleDashboardServing,
        dashboardPort: UInt16,
        accessStore: WebDashboardAccessStore,
        statusStore: WebDashboardStatusStore,
        diagnostics: DiagnosticStore = .shared,
        retryWait: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.service = service
        self.dashboardPort = dashboardPort
        self.accessStore = accessStore
        self.statusStore = statusStore
        self.diagnostics = diagnostics
        self.retryWait = retryWait
    }

    @discardableResult
    func startMonitoring(
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onInitialInspection: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never> {
        if monitoringEnabled {
            return monitoringTask ?? Task {}
        }
        stopped = false
        monitoringEnabled = true
        let observer = wakeNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemDidWake() }
        }
        wakeObserver = (wakeNotifications, observer)
        return startRecovery(onInitialInspection: onInitialInspection)
    }

    func stopMonitoring() {
        stopped = true
        monitoringEnabled = false
        revision += 1
        monitoringID = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        operation?.task.cancel()
        if let (center, observer) = wakeObserver {
            center.removeObserver(observer)
        }
        wakeObserver = nil
    }

    func systemDidWake() {
        guard monitoringEnabled, !stopped else { return }
        // A manual operation already ends with a fresh inspection.
        if let operation, operation.action != .inspect { return }
        monitoringTask?.cancel()
        startRecovery()
    }

    func refresh() async {
        guard await perform(.inspect), monitoringEnabled,
            monitoringID == nil else { return }
        if case .ready = state { return }
        startRecovery(afterInspection: true)
    }

    func enable() async {
        guard !stopped, !Task.isCancelled else { return }
        guard case .available(let host) = state else { return }
        state = .enabling(host: host)
        _ = await perform(.enable)
    }

    func disable() async {
        guard !stopped, !Task.isCancelled else { return }
        guard case .ready(let host) = state else { return }
        state = .disabling(host: host)
        _ = await perform(.disable)
    }

    @discardableResult
    private func startRecovery(
        afterInspection: Bool = false,
        onInitialInspection: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        let id = UUID()
        monitoringID = id
        let task = Task { [weak self] in
            defer {
                if self?.monitoringID == id { self?.monitoringID = nil }
            }
            let delays: [Duration] = [1, 2, 4, 8, 16, 30, 60].map {
                .seconds($0)
            }
            var attempt = 0
            var needsInspection = !afterInspection
            var initialInspection = onInitialInspection
            while let self, self.monitoringID == id, !Task.isCancelled {
                var inspected = true
                if needsInspection {
                    inspected = await self.perform(.inspect)
                    guard !Task.isCancelled,
                        self.monitoringID == id else { return }
                }
                // A cancelled coalesced caller can cancel the shared worker,
                // but must not end this still-active recovery lifetime.
                if inspected {
                    initialInspection?()
                    initialInspection = nil
                }
                if inspected, case .ready = self.state { return }
                do {
                    try await self.retryWait(delays[min(attempt, delays.count - 1)])
                } catch {
                    return
                }
                attempt = min(attempt + 1, delays.count - 1)
                needsInspection = true
            }
        }
        monitoringTask = task
        return task
    }

    private func perform(_ action: Action) async -> Bool {
        guard !stopped, !Task.isCancelled else { return false }
        if action != .inspect {
            revision += 1
            monitoringID = nil
            monitoringTask?.cancel()
            monitoringTask = nil
            operation?.task.cancel()
        }

        let current: Operation
        if action == .inspect, let operation, !operation.task.isCancelled {
            current = operation
        } else {
            let previous = operation?.task
            let service = self.service
            let dashboardPort = self.dashboardPort
            let worker = Task.detached(priority: .utility) {
                // Cancellation cannot interrupt a synchronous bounded process.
                // Keep its slot until it exits, even when its result is obsolete.
                _ = await previous?.value
                do {
                    try Task.checkCancellation()
                    switch action {
                    case .inspect: break
                    case .enable: try service.enable(dashboardPort: dashboardPort)
                    case .disable: try service.disable()
                    }
                    try Task.checkCancellation()
                    let inspection = try service.inspect(dashboardPort: dashboardPort)
                    try Task.checkCancellation()
                    if action == .enable, case .ready = inspection {
                        return Result<TailscaleDashboardInspection,
                            TailscaleDashboardFailure>.success(inspection)
                    } else if action == .enable {
                        return .failure(.verificationFailed)
                    }
                    return .success(inspection)
                } catch let failure as TailscaleDashboardFailure {
                    return .failure(failure)
                } catch BoundedProcessError.timedOut {
                    return .failure(.timedOut)
                } catch {
                    return .failure(.commandFailed)
                }
            }
            current = Operation(
                id: UUID(), action: action, revision: revision, task: worker
            )
            operation = current
        }
        let result = await withTaskCancellationHandler {
            await current.task.value
        } onCancel: {
            current.task.cancel()
        }
        let canPublish = !stopped && !Task.isCancelled
            && !current.task.isCancelled && revision == current.revision
        if operation?.id == current.id {
            operation = nil
            if canPublish {
                switch result {
                case .success(let inspection): apply(inspection)
                case .failure(let failure):
                    // An uncertain CLI failure is not evidence to revoke a
                    // previously accepted host. A confirmed offline node is.
                    if failure == .offline { publishLocalMode() }
                    state = .failed(failure)
                }
                recordDiagnosticTransition()
            }
        }
        if action != .inspect, canPublish, monitoringEnabled {
            if case .ready = state { return canPublish }
            startRecovery(afterInspection: true)
        }
        return canPublish
    }

    private func recordDiagnosticTransition() {
        guard state != lastDiagnosticState else { return }
        lastDiagnosticState = state
        let status: DiagnosticStatus
        switch state {
        case .ready: status = .recovered
        case .signedOut: status = .authenticationRequired
        case .unavailable, .available: status = .blocked
        case .failed(.timedOut): status = .timedOut
        case .failed(.invalidStatus): status = .invalidResponse
        case .failed(.offline): status = .transient
        case .failed(.commandFailed), .failed(.verificationFailed): status = .failed
        case .checking, .enabling, .disabling: return
        }
        diagnostics.record(DiagnosticEvent(
            status: status,
            category: .tailscaleDashboard
        ))
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
