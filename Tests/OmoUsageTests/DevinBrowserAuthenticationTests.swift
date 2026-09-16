import Foundation
import CryptoKit
import Network
import Testing
@testable import OmoUsage

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DevinBrowserAuthenticationTests {
    @Test
    func browserOpenFailureIsReportedAfterListenerBinds() async throws {
        var opened = false
        var callback: URL?
        do {
            _ = try await DevinBrowserAuthenticationClient().authenticate { url in
                opened = true
                #expect(url.host == "app.devin.ai")
                callback = Self.callbackURL(url)
                return false
            }
            Issue.record("Browser-open failure unexpectedly succeeded")
        } catch {
            #expect(error as? DevinBrowserAuthenticationError == .browserOpenFailed)
        }
        #expect(opened, "Authentication must bind its callback listener and attempt browser opening")
        if let callback { await Self.expectClosed(callback) }
    }

    @Test
    func realHTTPWrongStateThenValidAndDuplicateExchangeOnce() async throws {
        let exchange = DevinTransportExchangeGate()
        let flow = try await Self.begin(exchange: { try await exchange.exchange($0) })
        defer { flow.task.cancel() }
        let items = URLComponents(url: flow.authorization, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(flow.authorization.path == "/auth/cli/continue")
        #expect(Set(query.keys) == [
            "redirect_uri", "state", "prompt", "code_challenge", "code_challenge_method"
        ])
        #expect(query["prompt"] == "select_account")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"]?.count == 43)
        #expect(flow.callback.host == "127.0.0.1")
        #expect(flow.callback.port != nil && flow.callback.port != 0)

        let wrong = try await Self.http(flow.callback, query: "code=fixture-code&state=wrong")
        #expect(wrong == 400)
        #expect(exchange.requests.isEmpty)
        print("TRANSPORT HTTP wrong-state -> 400; exchanges=0; query redacted")
        let valid = try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)")
        #expect(valid == 200)
        let request = try await exchange.started.nextValue()
        let duplicate = try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)")
        #expect(duplicate == 409)
        #expect(exchange.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.devin.ai/auth/cli/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let requestBody = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: requestBody)
        let body = try #require(json as? [String: String])
        #expect(Set(body.keys) == ["code", "code_verifier"])
        #expect(body["code"] == "fixture-code")
        let verifier = try #require(body["code_verifier"])
        #expect(verifier.count == 43)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        #expect(Self.base64URL(digest) == query["code_challenge"])
        #expect(verifier != flow.state)
        exchange.release(Data(#"{"token":"header.eyJleHAiOjE4MDAwMDAwMDB9.signature"}"#.utf8))
        let snapshot = try await flow.task.value
        #expect(snapshot.provider == .devin)
        #expect(snapshot.accessToken.hasPrefix("devin-session-token$"))
        #expect(snapshot.source == .keychain)
        #expect(snapshot.refreshToken == nil)
        #expect(snapshot.accountReference == "https://server.codeium.com")
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        await Self.expectClosed(flow.callback)
        print("TRANSPORT HTTP valid -> 200; duplicate -> 409; exchanges=1; listener closed")
    }

    @Test(arguments: [
        "wrong-host", "duplicate-host", "wrong-path", "encoded-path", "post",
        "duplicate-state", "duplicate-code", "encoded-duplicate", "empty-code",
        "bad-percent", "wrong-state-error", "missing-state-error", "body", "absolute-target"
    ])
    func malformedCallbacksCannotConsumeAttempt(_ variant: String) async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data(#"{"token":"fixture-token"}"#.utf8)
        })
        defer { flow.task.cancel() }
        let host = "127.0.0.1:\(flow.callback.port!)"
        var target = "/callback?code=fixture-code&state=\(flow.state)"
        var headers = "Host: \(host)\r\n"
        var method = "GET"
        var body = ""
        switch variant {
        case "wrong-host": headers = "Host: localhost:\(flow.callback.port!)\r\n"
        case "duplicate-host": headers += "Host: \(host)\r\n"
        case "wrong-path": target = target.replacingOccurrences(of: "/callback", with: "/other")
        case "encoded-path": target = target.replacingOccurrences(of: "/callback", with: "/%63allback")
        case "post": method = "POST"
        case "duplicate-state": target += "&state=\(flow.state)"
        case "duplicate-code": target += "&code=another"
        case "encoded-duplicate": target += "&%73tate=\(flow.state)"
        case "empty-code": target = "/callback?code=&state=\(flow.state)"
        case "bad-percent": target = "/callback?code=%ZZ&state=\(flow.state)"
        case "wrong-state-error": target = "/callback?error=denied&state=wrong"
        case "missing-state-error": target = "/callback?error=denied"
        case "body": headers += "Content-Length: 1\r\n"; body = "x"
        case "absolute-target": target = "http://\(host)\(target)"
        default: Issue.record("Unknown malformed callback fixture")
        }
        let response = try await DevinTransportRawHTTP.send(
            port: UInt16(flow.callback.port!),
            request: "\(method) \(target) HTTP/1.1\r\n\(headers)\r\n\(body)"
        )
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(exchanges == 0)
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await flow.task.value
        #expect(exchanges == 1)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func verifiedProviderErrorTerminatesWithoutExchange() async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data()
        })
        #expect(try await Self.http(flow.callback, query: "error=denied&state=\(flow.state)") == 400)
        await Self.expectFailure(flow.task, .authorizationDenied)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutCloseWaitingListener(timeout: Bool) async throws {
        let signal = DevinTransportEvent<Void>()
        var exchanges = 0
        let flow = try await Self.begin(
            exchange: { _ in exchanges += 1; return Data() },
            timeout: { _ = try await signal.nextValue() }
        )
        if timeout { signal.send(()) } else { flow.task.cancel() }
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
        print("TRANSPORT \(timeout ? "timeout" : "cancel") waiting -> listener closed; exchanges=0")
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutPreventLateExchangeSuccess(timeout: Bool) async throws {
        let signal = DevinTransportEvent<Void>()
        let exchange = DevinTransportExchangeGate()
        let flow = try await Self.begin(
            exchange: { try await exchange.exchange($0) },
            timeout: { _ = try await signal.nextValue() }
        )
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await exchange.started.nextValue()
        if timeout { signal.send(()) } else { flow.task.cancel() }
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        await Self.expectClosed(flow.callback)
        exchange.release(Data(#"{"token":"fixture-late-token"}"#.utf8))
        _ = try await exchange.finished.nextValue()
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        #expect(exchange.requests.count == 1)
        print("TRANSPORT \(timeout ? "timeout" : "cancel") during exchange -> no late success; listener closed")
    }

    @Test
    func alreadyCancelledTaskDoesNotOpenBrowser() async {
        var opened = false
        let task = Task {
            try await DevinBrowserAuthenticationClient().authenticate { _ in
                opened = true
                return true
            }
        }
        task.cancel()
        await Self.expectFailure(task, nil)
        #expect(!opened)
    }

    @Test(arguments: ["fixture-token", "devin-session-token$fixture-token"])
    func tokenPrefixIsNormalizedWithoutInventedExpiry(_ token: String) async throws {
        let flow = try await Self.begin(exchange: { _ in
            try JSONSerialization.data(withJSONObject: ["token": token])
        })
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        let snapshot = try await flow.task.value
        #expect(snapshot.accessToken == "devin-session-token$fixture-token")
        #expect(snapshot.expiresAt == nil)
        #expect(snapshot.refreshToken == nil)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: ["{}", #"{"token":""}"#, #"{"token":"devin-session-token$"}"#, #"{"token":42}"#, "not-json"])
    func invalidExchangePayloadDoesNotAuthenticate(_ json: String) async throws {
        let flow = try await Self.begin(exchange: { _ in Data(json.utf8) })
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        await Self.expectFailure(flow.task, .invalidToken)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func attemptsUseIndependentRandomStateAndChallenges() async throws {
        let first = try await Self.begin(exchange: { _ in Data() })
        let second = try await Self.begin(exchange: { _ in Data() })
        first.task.cancel()
        second.task.cancel()
        #expect(first.state != second.state)
        let firstChallenge = URLComponents(url: first.authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code_challenge" }?.value
        let secondChallenge = URLComponents(url: second.authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code_challenge" }?.value
        #expect(firstChallenge != secondChallenge)
        await Self.expectFailure(first.task, nil)
        await Self.expectFailure(second.task, nil)
        await Self.expectClosed(first.callback)
        await Self.expectClosed(second.callback)
    }

    @Test
    func timeoutBeforeBrowserOpeningRetainsTimeoutError() async {
        var opened = false
        let task = Task {
            try await DevinBrowserAuthenticationClient(
                exchange: { _ in Data() }, timeout: {}
            ).authenticate { _ in
                opened = true
                return true
            }
        }
        await Self.expectFailure(task, .timedOut)
        #expect(!opened)
    }

    @Test(arguments: [false, true])
    func asyncBrowserOpenerCannotReturnLateSuccess(timeout: Bool) async throws {
        let opened = DevinTransportEvent<URL>()
        let release = DevinTransportEvent<Void>()
        let timeoutSignal = DevinTransportEvent<Void>()
        let timeoutReturned = DevinTransportEvent<Void>()
        let task = Task {
            try await DevinBrowserAuthenticationClient(
                exchange: { _ in Issue.record("Unexpected exchange"); return Data() },
                timeout: {
                    _ = try await timeoutSignal.nextValue()
                    timeoutReturned.send(())
                }
            ).authenticate { url in
                opened.send(url)
                _ = try? await release.nextValue()
                return true
            }
        }
        let url = try await opened.nextValue()
        let callback = try #require(Self.callbackURL(url))
        if timeout {
            timeoutSignal.send(())
            _ = try await timeoutReturned.nextValue()
            release.send(())
        } else {
            task.cancel()
        }
        await Self.expectFailure(task, timeout ? .timedOut : nil)
        await Self.expectClosed(callback)
    }

    @Test
    func oversizedIncompleteRequestIsRejectedWithoutExchange() async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data(#"{"token":"fixture-token"}"#.utf8)
        })
        defer { flow.task.cancel() }
        let response = try await DevinTransportRawHTTP.send(
            port: UInt16(flow.callback.port!),
            request: "GET /callback?" + String(repeating: "x", count: 8_192)
        )
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(exchanges == 0)
        flow.task.cancel()
        await Self.expectFailure(flow.task, nil)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: ["success", "redirect", "status-error", "declared-large", "streamed-large"])
    func ephemeralExchangeRejectsRedirectStatusAndOversizedBodies(_ mode: String) async throws {
        let server = try DevinTransportHTTPFixture(mode: mode)
        let url = try await server.start()
        do {
            let data = try await DevinBrowserAuthenticationHTTP.exchange(URLRequest(url: url))
            #expect(mode == "success")
            #expect(data == Data(#"{"token":"fixture-token"}"#.utf8))
        } catch {
            #expect(mode != "success")
            #expect(error as? DevinBrowserAuthenticationError == .exchangeFailed)
        }
        await server.close()
        #expect(server.requestCount == 1)
        await Self.expectClosed(url)
        print("TRANSPORT exchange \(mode) -> bounded result; requests=1; fixture listener closed")
    }

    private static func begin(
        exchange: @escaping DevinBrowserAuthenticationClient.Exchange,
        timeout: DevinBrowserAuthenticationClient.Timeout? = nil
    ) async throws -> (
        task: Task<CredentialSnapshot, Error>, authorization: URL, callback: URL, state: String
    ) {
        let opened = DevinTransportEvent<URL>()
        let task = Task {
            do {
                return try await DevinBrowserAuthenticationClient(
                    exchange: exchange, timeout: timeout
                ).authenticate { url in
                    opened.send(url)
                    return true
                }
            } catch {
                opened.fail(error)
                throw error
            }
        }
        do {
            let authorization = try await opened.nextValue()
            let callback = try #require(callbackURL(authorization))
            let state = try #require(URLComponents(
                url: authorization, resolvingAgainstBaseURL: false
            )?.queryItems?.first { $0.name == "state" }?.value)
            return (task, authorization, callback, state)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    private static func callbackURL(_ authorization: URL) -> URL? {
        URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    private static func http(_ callback: URL, query: String = "") async throws -> Int {
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.isEmpty ? nil : query
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: components.url!)
        return (response as! HTTPURLResponse).statusCode
    }

    private static func expectClosed(_ callback: URL) async {
        do {
            _ = try await http(callback)
            Issue.record("Callback listener still accepts HTTP after authentication ended")
        } catch {
            let code = (error as? URLError)?.code
            #expect(code == .cannotConnectToHost || code == .networkConnectionLost)
        }
    }

    private static func expectFailure(
        _ task: Task<CredentialSnapshot, Error>,
        _ expected: DevinBrowserAuthenticationError?
    ) async {
        do {
            _ = try await task.value
            Issue.record("Authentication unexpectedly succeeded")
        } catch {
            if let expected {
                #expect(error as? DevinBrowserAuthenticationError == expected)
            } else {
                #expect(error is CancellationError)
            }
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class DevinTransportEvent<Value: Sendable> {
    private let stream: AsyncThrowingStream<Value, Error>
    private let continuation: AsyncThrowingStream<Value, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ value: Value) { continuation.yield(value) }
    func fail(_ error: Error) { continuation.finish(throwing: error) }

    func nextValue() async throws -> Value {
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        return try #require(value)
    }
}

@MainActor
private final class DevinTransportHTTPFixture {
    private let listener: NWListener
    private let mode: String
    private let ready = DevinTransportEvent<URL>()
    private var cancelled = false
    private var peers: [ObjectIdentifier: NWConnection] = [:]
    private var closed: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(mode: String) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready.send(URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/token")!)
                case .failed(let error):
                    self.ready.fail(error)
                    self.listener.cancel()
                case .cancelled:
                    self.cancelled = true
                    self.listener.stateUpdateHandler = nil
                    self.listener.newConnectionHandler = nil
                    self.finishClose()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
        return try await ready.nextValue()
    }

    func close() async {
        listener.cancel()
        for peer in peers.values { peer.cancel() }
        if cancelled && peers.isEmpty { return }
        await withCheckedContinuation { closed = $0 }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        peers[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch state {
                case .ready: self.receive(connection, accumulated: Data())
                case .failed: connection.cancel()
                case .cancelled:
                    self.peers.removeValue(forKey: id)
                    connection.stateUpdateHandler = nil
                    self.finishClose()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var request = accumulated
                if let data { request.append(data) }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.requestCount += 1
                    self.respond(connection)
                } else if error != nil || done || request.count > 8_192 {
                    connection.cancel()
                } else {
                    self.receive(connection, accumulated: request)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection) {
        let fixture = #"{"token":"fixture-token"}"#
        let headers: String
        let body: String
        switch mode {
        case "redirect":
            headers = "302 Found\r\nLocation: http://127.0.0.1:\(listener.port!.rawValue)/redirect-target\r\nContent-Length: 0"
            body = ""
        case "status-error":
            headers = "401 Unauthorized\r\nContent-Length: 0"
            body = ""
        case "declared-large":
            headers = "200 OK\r\nContent-Length: 65537"
            body = String(repeating: "x", count: 65_537)
        case "streamed-large":
            headers = "200 OK"
            body = String(repeating: "x", count: 65_537)
        default:
            headers = "200 OK\r\nContent-Length: \(fixture.utf8.count)"
            body = fixture
        }
        connection.send(
            content: Data("HTTP/1.1 \(headers)\r\nConnection: close\r\n\r\n\(body)".utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func finishClose() {
        guard cancelled, peers.isEmpty else { return }
        closed?.resume()
        closed = nil
    }
}

@MainActor
private final class DevinTransportExchangeGate {
    var requests: [URLRequest] = []
    let started = DevinTransportEvent<URLRequest>()
    let finished = DevinTransportEvent<Void>()
    private var continuation: CheckedContinuation<Data, Never>?

    func exchange(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        let data = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.send(request)
        }
        finished.send(())
        return data
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
private final class DevinTransportRawHTTP {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Error>?
    private var response = Data()

    private init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func send(port: UInt16, request: String) async throws -> String {
        let client = DevinTransportRawHTTP(port: port)
        return try await client.send(request)
    }

    private func send(_ request: String) async throws -> String {
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        // The suite's time limit cancels the task; no fixed-delay test work.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                                MainActor.assumeIsolated {
                                    if let error { self.finish(.failure(error)) }
                                    else { self.receive() }
                                }
                            })
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
            MainActor.assumeIsolated {
                if let data { self.response.append(data) }
                // Content-Length, not EOF, defines completion. A peer may reset
                // after sending its rejection when excess request bytes remain unread.
                if let boundary = self.response.range(of: Data("\r\n\r\n".utf8)),
                   let headers = String(data: self.response[..<boundary.lowerBound], encoding: .utf8),
                   let lengthLine = headers.components(separatedBy: "\r\n").first(where: {
                       $0.lowercased().hasPrefix("content-length:")
                   }),
                   let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                   self.response.count >= boundary.upperBound + length {
                    self.finish(.success(String(decoding: self.response, as: UTF8.self)))
                } else if let error { self.finish(.failure(error)) }
                else if done { self.finish(.failure(URLError(.badServerResponse))) }
                else { self.receive() }
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
