import Foundation
import CryptoKit
import Network
import Testing
@testable import OmoUsage

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CodexBrowserAuthenticationTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func authorizeURLAndExchangeFollowCodexCLIContract() async throws {
        let exchange = CodexAuthExchangeGate()
        let flow = try await begin(exchange: { try await exchange.exchange($0) })
        defer { flow.task.cancel() }
        let components = try #require(URLComponents(url: flow.authorization, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/oauth/authorize")
        #expect(Set(query.keys) == [
            "response_type", "client_id", "redirect_uri", "scope", "code_challenge",
            "code_challenge_method", "id_token_add_organizations", "codex_cli_simplified_flow",
            "originator", "state"
        ])
        #expect(query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(query["scope"] == "openid profile email offline_access")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["originator"] == "codex_cli_rs")
        #expect(flow.callback.host == "127.0.0.1")
        #expect(flow.callback.path == "/auth/callback")

        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        let request = try await exchange.started.nextValue()
        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        try ProviderContractCatalog.endpoint(.codexTokenExchange, for: .codex).validate(request)
        let form = try Self.form(try #require(request.httpBody))
        #expect(Set(form.keys) == ["grant_type", "code", "redirect_uri", "client_id", "code_verifier"])
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "fixture-code")
        #expect(form["redirect_uri"] == flow.callback.absoluteString)
        let verifier = try #require(form["code_verifier"])
        #expect(query["code_challenge"] == Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(verifier != flow.state)

        let expiry = now.addingTimeInterval(7200)
        exchange.release(Self.tokenResponse(
            access: Self.jwt(["exp": expiry.timeIntervalSince1970]),
            id: Self.jwt([
                "email": "fixture@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account"]
            ])
        ))
        let snapshot = try await flow.task.value
        #expect(snapshot.provider == .codex)
        #expect(snapshot.refreshToken == "fixture-refresh")
        #expect(snapshot.accountReference == "fixture-account")
        #expect(snapshot.expiresAt == expiry)
        #expect(snapshot.email == "fixture@example.com")
        #expect(snapshot.source == .keychain)
    }

    @Test
    func callbackWithUnrecognizedParametersIsAccepted() async throws {
        let exchange = CodexAuthExchangeGate()
        let flow = try await begin(exchange: { try await exchange.exchange($0) })
        defer { flow.task.cancel() }
        let query = "code=fixture-code&scope=openid+profile+email+offline_access&state=\(flow.state)"
        try #require(try await Self.http(flow.callback, query: query) == 200)
        let request = try await exchange.started.nextValue()
        #expect(try Self.form(try #require(request.httpBody))["code"] == "fixture-code")
    }

    @Test
    func busyRegisteredPortNeverFallsBackToAnUnregisteredPort() async throws {
        let occupant = try CodexAuthPortOccupant()
        let busy = try await occupant.start()
        defer { occupant.close() }
        do {
            _ = try await begin(exchange: { _ in Data() }, ports: [busy])
            Issue.record("Sign-in must not start on an unregistered redirect port")
        } catch {
            #expect(error as? ClaudeBrowserAuthenticationError == .listenerFailed)
        }
    }

    @Test(arguments: ["missing-id-token", "missing-account-claim", "missing-refresh"])
    func incompleteGrantDoesNotAuthenticate(_ variant: String) throws {
        let access = Self.jwt(["exp": now.addingTimeInterval(60).timeIntervalSince1970])
        let accountClaim: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "a"]]
        var body: [String: Any] = [
            "access_token": access, "refresh_token": "r", "id_token": Self.jwt(accountClaim)
        ]
        switch variant {
        case "missing-id-token": body["id_token"] = nil
        case "missing-account-claim": body["id_token"] = Self.jwt(["email": "e@example.com"])
        default: body["refresh_token"] = nil
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(throws: ClaudeBrowserAuthenticationError.invalidToken) {
            try CodexBrowserAuthenticationClient.snapshot(data, now: now)
        }
    }

    private func begin(
        exchange: @escaping ClaudeBrowserAuthenticationClient.Exchange,
        ports: [UInt16] = [0]
    ) async throws -> (task: Task<CredentialSnapshot, Error>, authorization: URL, callback: URL, state: String) {
        let opened = CodexAuthEvent<URL>()
        let fixedNow = now
        let task = Task {
            do {
                return try await CodexBrowserAuthenticationClient(
                    exchange: exchange,
                    timeout: { _ = try await CodexAuthEvent<Void>().nextValue() },
                    now: { fixedNow },
                    ports: ports
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

    private static func http(_ callback: URL, query: String) async throws -> Int {
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: components.url!)
        return (response as! HTTPURLResponse).statusCode
    }

    private static func form(_ body: Data) throws -> [String: String] {
        let text = try #require(String(data: body, encoding: .utf8))
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }

    private static func tokenResponse(access: String, id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": "fixture-refresh", "id_token": id
        ])
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        return "header.\(base64URL(payload)).signature"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class CodexAuthEvent<Value: Sendable> {
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
private final class CodexAuthExchangeGate {
    let started = CodexAuthEvent<URLRequest>()
    private var continuation: CheckedContinuation<Data, Never>?

    func exchange(_ request: URLRequest) async throws -> Data {
        await withCheckedContinuation { continuation in
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
private final class CodexAuthPortOccupant {
    private let listener: NWListener
    private let ready = CodexAuthEvent<UInt16>()

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
