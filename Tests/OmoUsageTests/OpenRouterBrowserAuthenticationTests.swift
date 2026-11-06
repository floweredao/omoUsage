import Foundation
import CryptoKit
import Testing
@testable import OmoUsage

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OpenRouterBrowserAuthenticationTests {
    @Test
    func signInFollowsOpenRouterPKCEContractAndReturnsTheMintedKey() async throws {
        let exchange = OpenRouterAuthExchangeGate()
        let opened = OpenRouterAuthEvent<URL>()
        let task = Task {
            try await OpenRouterBrowserAuthenticationClient(
                exchange: { try await exchange.exchange($0) },
                timeout: { _ = try await OpenRouterAuthEvent<Void>().nextValue() }
            ).authenticate { url in
                opened.send(url)
                return true
            }
        }
        defer { task.cancel() }
        let authorization = try await opened.nextValue()
        let components = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        #expect(components.host == "openrouter.ai")
        #expect(components.path == "/auth")
        #expect(Set(query.keys) == ["callback_url", "code_challenge", "code_challenge_method", "key_label", "state"])
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["key_label"] == "OmoUsage")
        let callback = try #require(query["callback_url"].flatMap(URL.init(string:)))
        #expect(callback.host == "localhost")
        #expect(callback.path == "/callback")
        let state = try #require(query["state"])

        #expect(try await Self.http(callback, query: "code=fixture-code&state=\(state)") == 200)
        let request = try await exchange.started.nextValue()
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        #expect(request.httpMethod == "POST")
        try ProviderContractCatalog.endpoint(.openRouterKeyExchange, for: .openrouter).validate(request)
        let requestBody = try #require(request.httpBody)
        let body = try #require(
            try JSONSerialization.jsonObject(with: requestBody) as? [String: String]
        )
        #expect(Set(body.keys) == ["code", "code_verifier", "code_challenge_method"])
        #expect(body["code"] == "fixture-code")
        #expect(body["code_challenge_method"] == "S256")
        let verifier = try #require(body["code_verifier"])
        #expect(query["code_challenge"] == Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))

        exchange.release(Data(#"{"key":"sk-or-fixture","user_id":"fixture-user"}"#.utf8))
        #expect(try await task.value == "sk-or-fixture")
    }

    @Test(arguments: ["{}", #"{"key":""}"#, #"{"key":"has space"}"#, "not-json"])
    func responseWithoutAUsableKeyIsRejected(_ json: String) {
        #expect(throws: ClaudeBrowserAuthenticationError.invalidToken) {
            try OpenRouterBrowserAuthenticationClient.keySnapshot(Data(json.utf8))
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

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class OpenRouterAuthEvent<Value: Sendable> {
    private let stream: AsyncThrowingStream<Value, Error>
    private let continuation: AsyncThrowingStream<Value, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ value: Value) { continuation.yield(value) }

    func nextValue() async throws -> Value {
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        return try #require(value)
    }
}

@MainActor
private final class OpenRouterAuthExchangeGate {
    let started = OpenRouterAuthEvent<URLRequest>()
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
