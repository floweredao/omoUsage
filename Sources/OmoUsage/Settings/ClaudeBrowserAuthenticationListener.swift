import Foundation
import Network

/// Where a provider's registered OAuth redirect may land. Claude accepts any
/// loopback port; Codex accepts only the ports its CLI registered.
struct BrowserAuthenticationCallback: Equatable, Sendable {
    var providerName: String
    var redirectHost: String
    var path: String
    var ports: [UInt16]
    var allowsEphemeralPort: Bool

    static func claude(preferredPort: UInt16) -> BrowserAuthenticationCallback {
        BrowserAuthenticationCallback(
            providerName: "Claude",
            redirectHost: "localhost",
            path: "/callback",
            ports: preferredPort == 0 ? [] : [preferredPort],
            allowsEphemeralPort: true
        )
    }
}

/// Loopback-only OAuth callback. Binds 127.0.0.1 on the first free configured
/// port, falling back to an ephemeral port only when the provider allows it,
/// and accepts only `GET <path>`. All Network callbacks run on the main queue.
@MainActor
final class ClaudeBrowserAuthenticationListener {
    static let maximumConnections = 8
    static let maximumRequestBytes = 8_192

    var callback: ((Result<String, ClaudeBrowserAuthenticationError>) -> Void)?
    private(set) var port: UInt16?
    private var listener: NWListener
    /// Ports still to try after the current one; `.any` is the ephemeral fallback.
    private var remainingPorts: [NWEndpoint.Port]
    private let configuration: BrowserAuthenticationCallback
    private let state: String
    private var expectedHosts: Set<String> = []
    private var started = false
    private var stopping = false
    private var listenerCancelled = false
    private var consumed = false
    private var ready: CheckedContinuation<URL, Error>?
    private var closed: CheckedContinuation<Void, Never>?
    private var connections: [ObjectIdentifier: Peer] = [:]

    private struct Peer {
        let connection: NWConnection
        let deadline: DispatchWorkItem
    }

    convenience init(state: String, preferredPort: UInt16) throws {
        try self.init(state: state, configuration: .claude(preferredPort: preferredPort))
    }

    init(state: String, configuration: BrowserAuthenticationCallback) throws {
        self.state = state
        self.configuration = configuration
        var ports = configuration.ports.compactMap { NWEndpoint.Port(rawValue: $0) }
        if configuration.allowsEphemeralPort { ports.append(.any) }
        while !ports.isEmpty {
            let port = ports.removeFirst()
            if let candidate = try? Self.makeListener(port: port) {
                listener = candidate
                remainingPorts = ports
                return
            }
        }
        throw ClaudeBrowserAuthenticationError.listenerFailed
    }

    private static func makeListener(port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        do { return try NWListener(using: parameters) }
        catch { throw ClaudeBrowserAuthenticationError.listenerFailed }
    }

    func start() async throws -> URL {
        guard !stopping else { throw ClaudeBrowserAuthenticationError.listenerFailed }
        return try await withCheckedThrowingContinuation { ready in
            self.ready = ready
            started = true
            startCurrentListener()
        }
    }

    private func startCurrentListener() {
        let current = listener
        let id = ObjectIdentifier(current)
        current.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state, listener: id) }
        }
        current.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, ObjectIdentifier(self.listener) == id else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        current.start(queue: .main)
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        ready?.resume(throwing: ClaudeBrowserAuthenticationError.listenerFailed)
        ready = nil
        if !started { listenerCancelled = true }
        listener.cancel()
        for peer in connections.values {
            peer.deadline.cancel()
            peer.connection.cancel()
        }
        resumeClosedIfReady()
    }

    /// Returns only after Network acknowledges cancellation of the listener and every peer.
    func close() async {
        stop()
        if listenerCancelled && connections.isEmpty { return }
        await withCheckedContinuation { closed = $0 }
    }

    private func listenerChanged(_ state: NWListener.State, listener id: ObjectIdentifier) {
        guard ObjectIdentifier(listener) == id else { return }
        switch state {
        case .ready:
            guard !stopping, let port = listener.port else { return }
            self.port = port.rawValue
            remainingPorts = []
            expectedHosts = ["localhost:\(port.rawValue)", "127.0.0.1:\(port.rawValue)"]
            ready?.resume(returning: URL(
                string: "http://\(configuration.redirectHost):\(port.rawValue)\(configuration.path)"
            )!)
            ready = nil
        case .waiting, .failed:
            if !stopping, fallBackToNextPort() { return }
            // A loopback listener waits only when its port is taken; with no
            // port left to try, waiting would hold the sign-in until timeout.
            callback?(.failure(.listenerFailed))
            stop()
        case .cancelled:
            listenerCancelled = true
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            resumeClosedIfReady()
        default:
            break
        }
    }

    private func fallBackToNextPort() -> Bool {
        guard !remainingPorts.isEmpty,
              let replacement = try? Self.makeListener(port: remainingPorts.removeFirst())
        else { return false }
        let busy = listener
        busy.stateUpdateHandler = nil
        busy.newConnectionHandler = nil
        busy.cancel()
        listener = replacement
        startCurrentListener()
        return true
    }

    private func accept(_ connection: NWConnection) {
        guard !stopping, connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        connections[id] = Peer(connection: connection, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch state {
                case .ready: self.receive(connection, accumulated: Data())
                case .failed: connection.cancel()
                case .cancelled:
                    self.connections.removeValue(forKey: id)?.deadline.cancel()
                    connection.stateUpdateHandler = nil
                    self.resumeClosedIfReady()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        guard !stopping else { connection.cancel(); return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumRequestBytes - accumulated.count
        ) { [weak self, weak connection] bytes, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                guard !self.stopping, error == nil else { connection.cancel(); return }
                var request = accumulated
                if let bytes { request.append(bytes) }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(to: request, on: connection)
                } else if complete || request.count >= Self.maximumRequestBytes {
                    self.send(status: 400, on: connection)
                } else {
                    self.receive(connection, accumulated: request)
                }
            }
        }
    }

    private enum Callback {
        case invalid
        case code(String)
        case denied
        case stateMismatch
    }

    private func parse(_ data: Data) -> Callback {
        guard data.count <= Self.maximumRequestBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n")
        else { return .invalid }
        let lines = text.dropLast(4).components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        let prefix = configuration.path + "?"
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix(prefix)
        else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  !pair[0].isEmpty,
                  pair[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
                  !pair[1].contains("\r"), !pair[1].contains("\n")
            else { return .invalid }
            let key = pair[0].lowercased()
            guard headers[key] == nil else { return .invalid }
            headers[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], expectedHosts.contains(host),
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0"
        else { return .invalid }
        var query: [String: String] = [:]
        for parameter in request[1].dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false) {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            // RFC 6749 4.1.2: ignore unrecognized response parameters (ChatGPT adds `scope`).
            guard let key = String(pair[0]).removingPercentEncoding,
                  ["code", "state", "error", "error_description"].contains(key)
            else { continue }
            guard pair.count == 2,
                  let value = String(pair[1]).removingPercentEncoding,
                  query[key] == nil,
                  value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
                  !parameter.contains("#")
            else { return .invalid }
            query[key] = value
        }
        // Validate state before interpreting a provider error or accepting any code.
        guard let received = query["state"], !received.isEmpty else { return .invalid }
        guard received == state else { return .stateMismatch }
        if let error = query["error"], !error.isEmpty, query["code"] == nil {
            return .denied
        }
        guard query["error"] == nil, query["error_description"] == nil,
              let code = query["code"], !code.isEmpty, code.utf8.count <= 2_048
        else { return .invalid }
        return .code(code)
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let parsed = parse(request)
        if case .invalid = parsed {
            send(status: 400, on: connection)
            return
        }
        guard !consumed else { send(status: 409, on: connection); return }
        consumed = true
        switch parsed {
        case .code(let code):
            send(status: 200, on: connection) { [weak self] in
                self?.callback?(.success(code))
            }
        case .denied:
            send(status: 400, on: connection) { [weak self] in
                self?.callback?(.failure(.authorizationDenied))
            }
        case .stateMismatch:
            send(status: 400, on: connection) { [weak self] in
                self?.callback?(.failure(.stateMismatch))
            }
        case .invalid:
            break
        }
    }

    private func send(
        status: Int,
        on connection: NWConnection,
        afterSend: (@MainActor () -> Void)? = nil
    ) {
        let message = status == 200
            ? "\(configuration.providerName) sign-in received. You can close this tab and return to OmoUsage."
            : "\(configuration.providerName) sign-in callback was not accepted."
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OmoUsage</title></head>"
            + "<body><p>\(message)</p></body></html>\n"
        let reason = status == 200 ? "OK" : status == 409 ? "Conflict" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'none'\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            MainActor.assumeIsolated {
                connection?.cancel()
                guard let self, !self.stopping else { return }
                if error == nil { afterSend?() }
                else if afterSend != nil { self.callback?(.failure(.listenerFailed)) }
            }
        })
    }

    private func resumeClosedIfReady() {
        guard listenerCancelled, connections.isEmpty else { return }
        callback = nil
        closed?.resume()
        closed = nil
    }
}
