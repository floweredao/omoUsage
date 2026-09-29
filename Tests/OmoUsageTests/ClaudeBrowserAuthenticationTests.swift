import Foundation
import CryptoKit
import Network
import Testing
@testable import OmoUsage

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ClaudeBrowserAuthenticationTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func authorizeURLAndExchangeFollowClaudePKCEContract() async throws {
        let exchange = ClaudeTransportExchangeGate()
        let flow = try await begin(exchange: { try await exchange.exchange($0) })
        defer { flow.task.cancel() }
        let components = try #require(URLComponents(url: flow.authorization, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "https")
        #expect(components.host == "claude.ai")
        #expect(components.path == "/oauth/authorize")
        #expect(Set(query.keys) == [
            "code", "client_id", "response_type", "redirect_uri", "scope",
            "code_challenge", "code_challenge_method", "state"
        ])
        #expect(query["code"] == "true")
        #expect(query["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["scope"] == "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
        #expect(flow.callback.scheme == "http")
        #expect(flow.callback.host == "localhost")
        #expect(flow.callback.path == "/callback")
        #expect(flow.callback.port != nil && flow.callback.port != 0)
        #expect(flow.state.count == 43)
        #expect(query["code_challenge"] == Self.base64URL(Data(SHA256.hash(data: Data(flow.state.utf8)))))

        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        let request = try await exchange.started.nextValue()
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 409)
        #expect(exchange.requests.count == 1)
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudeUsageProvider.cliUserAgent)
        try ProviderContractCatalog.endpoint(.claudeTokenExchange, for: .claude).validate(request)
        let requestBody = try #require(request.httpBody)
        let body = try #require(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: String]
        )
        #expect(Set(body.keys) == [
            "grant_type", "client_id", "code", "state", "redirect_uri", "code_verifier"
        ])
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(body["code"] == "fixture-code")
        #expect(body["state"] == flow.state)
        #expect(body["code_verifier"] == flow.state)
        #expect(body["redirect_uri"] == flow.callback.absoluteString)

        exchange.release(Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"account":{"email_address":"fixture@example.com"}}"#.utf8))
        let snapshot = try await flow.task.value
        #expect(snapshot.provider == .claude)
        #expect(snapshot.accessToken == "fixture-access")
        #expect(snapshot.refreshToken == "fixture-refresh")
        #expect(snapshot.expiresAt == now.addingTimeInterval(3600))
        #expect(snapshot.source == .keychain)
        #expect(snapshot.email == "fixture@example.com")
        await Self.expectClosed(flow.callback)
    }

    @Test
    func stateMismatchIsRejectedWithoutExchange() async throws {
        var exchanges = 0
        let flow = try await begin(exchange: { _ in
            exchanges += 1
            return Data()
        })
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=wrong") == 400)
        await Self.expectFailure(flow.task, .stateMismatch)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func providerErrorWithValidStateEndsAsDenied() async throws {
        var exchanges = 0
        let flow = try await begin(exchange: { _ in
            exchanges += 1
            return Data()
        })
        #expect(try await Self.http(flow.callback, query: "error=access_denied&state=\(flow.state)") == 400)
        await Self.expectFailure(flow.task, .authorizationDenied)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: ["wrong-path", "missing-state", "post", "wrong-host"])
    func malformedCallbacksDoNotConsumeAttempt(_ variant: String) async throws {
        var exchanges = 0
        let flow = try await begin(exchange: { _ in
            exchanges += 1
            return Data(#"{"access_token":"a","refresh_token":"r","expires_in":60}"#.utf8)
        })
        defer { flow.task.cancel() }
        let port = UInt16(flow.callback.port!)
        var target = "/callback?code=fixture-code&state=\(flow.state)"
        var method = "GET"
        var host = "localhost:\(port)"
        switch variant {
        case "wrong-path": target = target.replacingOccurrences(of: "/callback", with: "/other")
        case "missing-state": target = "/callback?code=fixture-code"
        case "post": method = "POST"
        case "wrong-host": host = "example.com"
        default: Issue.record("Unknown malformed callback fixture")
        }
        let response = try await ClaudeTransportRawHTTP.send(
            port: port,
            request: "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(exchanges == 0)
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await flow.task.value
        #expect(exchanges == 1)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: [false, true])
    func timeoutAndCancellationCloseWaitingListener(timeout: Bool) async throws {
        let signal = ClaudeTransportEvent<Void>()
        var exchanges = 0
        let flow = try await begin(
            exchange: { _ in exchanges += 1; return Data() },
            timeout: { _ = try await signal.nextValue() }
        )
        if timeout { signal.send(()) } else { flow.task.cancel() }
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func busyPreferredPortFallsBackToEphemeralPort() async throws {
        #expect(ClaudeBrowserAuthenticationClient.preferredCallbackPort == 53692)
        let occupant = try ClaudePortOccupant()
        let busy = try await occupant.start()
        defer { occupant.close() }
        let flow = try await begin(exchange: { _ in
            Data(#"{"access_token":"a","refresh_token":"r","expires_in":60}"#.utf8)
        }, preferredPort: busy)
        #expect(flow.callback.port != nil)
        #expect(flow.callback.port != Int(busy))
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await flow.task.value
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: [
        "{}", #"{"access_token":"a","expires_in":60}"#,
        #"{"access_token":"a","refresh_token":"r"}"#,
        #"{"access_token":"","refresh_token":"r","expires_in":60}"#, "not-json"
    ])
    func invalidExchangePayloadDoesNotAuthenticate(_ json: String) async throws {
        let flow = try await begin(exchange: { _ in Data(json.utf8) })
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        await Self.expectFailure(flow.task, .invalidToken)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: ["success", "redirect", "status-error"])
    func contractExchangeRejectsRedirectsAndErrors(_ mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeTokenExchangeURLProtocol.self]
        var request = try ClaudeBrowserAuthenticationClient.tokenRequest(
            code: "fixture-code", state: "fixture-state", verifier: "fixture-state",
            redirectURI: "http://localhost:1/callback"
        )
        request.url = URL(string: "https://fixture.invalid/\(mode)")
        do {
            let data = try await ClaudeBrowserAuthenticationHTTP.exchange(request, configuration: configuration)
            #expect(mode == "success")
            #expect(data == Data(ClaudeTokenExchangeURLProtocol.body.utf8))
        } catch {
            #expect(mode != "success")
            #expect(error as? ClaudeBrowserAuthenticationError == .exchangeFailed)
        }
    }

    private func begin(
        exchange: @escaping ClaudeBrowserAuthenticationClient.Exchange,
        timeout: ClaudeBrowserAuthenticationClient.Timeout? = nil,
        preferredPort: UInt16 = 0
    ) async throws -> (
        task: Task<CredentialSnapshot, Error>, authorization: URL, callback: URL, state: String
    ) {
        let opened = ClaudeTransportEvent<URL>()
        let fixedNow = now
        let task = Task {
            do {
                return try await ClaudeBrowserAuthenticationClient(
                    exchange: exchange,
                    timeout: timeout ?? { _ = try await ClaudeTransportEvent<Void>().nextValue() },
                    now: { fixedNow },
                    preferredPort: preferredPort
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
            let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems
            let callback = try #require(
                items?.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
            )
            let state = try #require(items?.first { $0.name == "state" }?.value)
            return (task, authorization, callback, state)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
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
        _ expected: ClaudeBrowserAuthenticationError?
    ) async {
        do {
            _ = try await task.value
            Issue.record("Authentication unexpectedly succeeded")
        } catch {
            if let expected {
                #expect(error as? ClaudeBrowserAuthenticationError == expected)
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
private final class ClaudeTransportEvent<Value: Sendable> {
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
private final class ClaudeTransportExchangeGate {
    var requests: [URLRequest] = []
    let started = ClaudeTransportEvent<URLRequest>()
    private var continuation: CheckedContinuation<Data, Never>?

    func exchange(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.send(request)
        }
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
private final class ClaudePortOccupant {
    private let listener: NWListener
    private let ready = ClaudeTransportEvent<UInt16>()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.ready.send(self.listener.port!.rawValue)
                case .failed(let error): self.ready.fail(error)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        return try await ready.nextValue()
    }

    func close() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}

@MainActor
private final class ClaudeTransportRawHTTP {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Error>?
    private var response = Data()

    private init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func send(port: UInt16, request: String) async throws -> String {
        try await ClaudeTransportRawHTTP(port: port).send(request)
    }

    private func send(_ request: String) async throws -> String {
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
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

private final class ClaudeTokenExchangeURLProtocol: URLProtocol {
    static let body = #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        switch url.lastPathComponent {
        case "redirect":
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://fixture.invalid/success"]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: URL(string: "https://fixture.invalid/success")!),
                redirectResponse: redirect
            )
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case "status-error":
            respond(401, "{}")
        default:
            respond(200, Self.body)
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
