import Foundation
import Network

/// All Network callbacks are scheduled on the main queue, matching the owning actor.
@MainActor
final class DevinBrowserAuthenticationListener {
    static let maximumConnections = 8
    static let maximumRequestBytes = 8_192

    var callback: ((Result<String, DevinBrowserAuthenticationError>) -> Void)?
    private let listener: NWListener
    private let state: String
    private var expectedHost = ""
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

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do { listener = try NWListener(using: parameters) }
        catch { throw DevinBrowserAuthenticationError.listenerFailed }
    }

    func start() async throws -> URL {
        guard !stopping else { throw DevinBrowserAuthenticationError.listenerFailed }
        return try await withCheckedThrowingContinuation { ready in
            self.ready = ready
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            started = true
            listener.start(queue: .main)
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        ready?.resume(throwing: DevinBrowserAuthenticationError.listenerFailed)
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

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard !stopping, let port = listener.port else { return }
            expectedHost = "127.0.0.1:\(port.rawValue)"
            ready?.resume(returning: URL(string: "http://\(expectedHost)/callback")!)
            ready = nil
        case .failed:
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
    }

    private func parse(_ data: Data) -> Callback {
        guard data.count <= Self.maximumRequestBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n")
        else { return .invalid }
        let lines = text.dropLast(4).components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix("/callback?")
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
        guard headers["host"] == expectedHost,
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0"
        else { return .invalid }
        var query: [String: String] = [:]
        for parameter in request[1].dropFirst("/callback?".count).split(separator: "&", omittingEmptySubsequences: false) {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let key = String(pair[0]).removingPercentEncoding,
                  let value = String(pair[1]).removingPercentEncoding,
                  ["code", "state", "error", "error_description"].contains(key),
                  query[key] == nil,
                  value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
                  !parameter.contains("#")
            else { return .invalid }
            query[key] = value
        }
        // Validate state before interpreting a provider error or accepting any code.
        guard query["state"] == state else { return .invalid }
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
        switch parsed {
        case .invalid:
            send(status: 400, on: connection)
        case .code, .denied:
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
            case .invalid:
                break
            }
        }
    }

    private func send(
        status: Int,
        on connection: NWConnection,
        afterSend: (@MainActor () -> Void)? = nil
    ) {
        let body = if status == 200 {
            "Authentication received. Return to the app.\n"
        } else {
            "Authentication callback not accepted.\n"
        }
        let reason = status == 200 ? "OK" : status == 409 ? "Conflict" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n\(body)"
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
