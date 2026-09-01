import Foundation
import Testing
@testable import OmoUsage

@Suite
struct GrokReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_786_032_000)

    @Test
    func mapsCurrentConfigAndSettingsFields() async throws {
        try await HephaestusGrokReliabilityFixture.withDirectory { home in
            try HephaestusGrokReliabilityFixture.writeCredential(home: home)

            let usage = try await HephaestusGrokReliabilityFixture.provider(
                home: home
            ).fetch(now: now)
            let meter = try #require(usage.groups.first?.meters.first)
            let expectedReset = try #require(
                ISO8601DateFormatter().date(
                    from: "2026-09-01T00:00:00Z"
                )
            )

            #expect(meter.percentRemaining == 63)
            #expect(meter.resetsAt == expectedReset)
            #expect(usage.groups.first?.meters.last?.metric ==
                .informational(value: "2500 한도")
            )
            #expect(usage.planName == "SuperGrok")
        }
    }

    @Test
    func expiredAccessTokenRefreshesAndPersistsRotatedCredentials() async throws {
        try await HephaestusGrokReliabilityFixture.withDirectory { home in
            try HephaestusGrokReliabilityFixture.writeCredential(
                home: home,
                accessToken: "header.eyJleHAiOjE3MDAwMDAwMDB9.signature",
                refreshToken: "grok-refresh-credential",
                issuer: "https://auth.grok.com",
                clientID: "grok-client"
            )
            let usage = try await HephaestusGrokReliabilityFixture.provider(
                home: home
            ).fetch(now: now)
            let auth = try UsageJSON.object(
                Data(
                    contentsOf: home.appending(path: ".grok/auth.json")
                )
            )
            let account = try #require(
                UsageJSON.object(auth["account"])
            )

            #expect(usage.provider == .grok)
            #expect(account["key"] as? String == "fresh-access-token")
            #expect(
                account["refresh_token"] as? String
                    == "rotated-refresh-token"
            )
        }
    }

    @Test
    func serverRejectedAccessTokenRefreshesAndRetriesOnce() async throws {
        try await HephaestusGrokReliabilityFixture.withDirectory { home in
            try HephaestusGrokReliabilityFixture.writeCredential(
                home: home,
                accessToken: "rejected-access-token",
                refreshToken: "grok-refresh-credential",
                issuer: "https://auth.grok.com",
                clientID: "grok-client"
            )

            let usage = try await HephaestusGrokReliabilityFixture.provider(
                home: home
            ).fetch(now: now)
            let auth = try UsageJSON.object(
                Data(
                    contentsOf: home.appending(path: ".grok/auth.json")
                )
            )
            let account = try #require(
                UsageJSON.object(auth["account"])
            )

            #expect(usage.provider == .grok)
            #expect(account["key"] as? String == "fresh-access-token")
        }
    }

    @Test
    func rejectsUntrustedRefreshIssuerBeforeSendingToken() async throws {
        try await HephaestusGrokReliabilityFixture.withDirectory { home in
            try HephaestusGrokReliabilityFixture.writeCredential(
                home: home,
                accessToken: "header.eyJleHAiOjE3MDAwMDAwMDB9.signature",
                refreshToken: "grok-refresh-credential",
                issuer: "https://attacker.example",
                clientID: "grok-client"
            )

            await #expect(
                throws: ProviderTransportError.invalidResponse(.grok)
            ) {
                try await HephaestusGrokReliabilityFixture.provider(
                    home: home
                ).fetch(now: now)
            }
        }
    }
}

/// Serialized: every case drives the same stubbed token endpoint, so
/// parallel execution would let one scenario answer another's refresh.
@Suite(.serialized)
struct GrokRefreshContractTests {
    private static let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func accessTokenExpiringWithinFiveMinutesIsRefreshed() async throws {
        GrokRefreshExchange.shared.reset()
        try await GrokRefreshFixture.withDirectory { home in
            try GrokRefreshFixture.writeCredential(
                home: home,
                expiresAt: 1_785_675_240,
                issuer: "https://auth.grok.com",
                clientID: "grok-client"
            )

            _ = try await GrokRefreshFixture.provider(home: home)
                .fetch(now: Self.now)

            #expect(GrokRefreshExchange.shared.tokenRequests() == 1)
            #expect(
                GrokRefreshExchange.shared.usageAuthorizations()
                    == ["Bearer fresh-access-token"]
            )
        }
    }

    @Test
    func accessTokenExpiringAfterFiveMinutesIsUsedWithoutRefresh()
        async throws
    {
        GrokRefreshExchange.shared.reset()
        try await GrokRefreshFixture.withDirectory { home in
            try GrokRefreshFixture.writeCredential(
                home: home,
                expiresAt: 1_785_675_360,
                issuer: "https://auth.grok.com",
                clientID: "grok-client"
            )

            _ = try await GrokRefreshFixture.provider(home: home)
                .fetch(now: Self.now)

            #expect(GrokRefreshExchange.shared.tokenRequests() == 0)
            #expect(
                GrokRefreshExchange.shared.usageAuthorizations()
                    == ["Bearer stored-access-token"]
            )
        }
    }

    @Test
    func refreshesThroughFixedEndpointWithoutStoredIssuer()
        async throws
    {
        GrokRefreshExchange.shared.reset()
        try await GrokRefreshFixture.withDirectory { home in
            try GrokRefreshFixture.writeCredential(
                home: home,
                expiresAt: 1_785_600_000,
                issuer: nil,
                clientID: "grok-client"
            )

            _ = try await GrokRefreshFixture.provider(home: home)
                .fetch(now: Self.now)

            #expect(
                GrokRefreshExchange.shared.tokenURLs()
                    == ["https://auth.x.ai/oauth2/token"]
            )
        }
    }

    @Test
    func percentEncodesRefreshFormValues() async throws {
        GrokRefreshExchange.shared.reset()
        try await GrokRefreshFixture.withDirectory { home in
            try GrokRefreshFixture.writeCredential(
                home: home,
                refreshToken: "grok+refresh credential",
                expiresAt: 1_785_600_000,
                issuer: "https://auth.grok.com",
                clientID: "grok-client"
            )

            _ = try await GrokRefreshFixture.provider(home: home)
                .fetch(now: Self.now)

            let form = try #require(GrokRefreshExchange.shared.lastForm())
            #expect(!form.contains("grok+refresh"))
            #expect(
                form.contains(
                    "refresh_token=grok%2Brefresh%20credential"
                )
            )
        }
    }
}

/// Serialized: every case drives the same stubbed endpoints, so parallel
/// execution would let one scenario answer another's request.
@Suite(.serialized)
struct GrokMultiAccountTests {
    private static let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func failedRefreshOnFirstAccountAdvancesToSecondAccount()
        async throws
    {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: ["second-access-token"],
            refreshFailureTokens: ["first-refresh"]
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "refresh_token": "first-refresh",
                    "oidc_client_id": "grok-client",
                    "expires_at": 1_785_600_000
                ]
            )

            _ = try await GrokAccountFixture.provider(home: home)
                .fetch(now: Self.now)

            #expect(
                GrokAccountExchange.shared.billingAuthorizations()
                    == ["Bearer second-access-token"]
            )
            #expect(GrokAccountExchange.shared.tokenRequests() == 1)
        }
    }

    @Test
    func rejectedNonRefreshableAccountAdvancesToSecondAccount()
        async throws
    {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: ["second-access-token"]
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "oidc_client_id": "grok-client"
                ]
            )

            _ = try await GrokAccountFixture.provider(home: home)
                .fetch(now: Self.now)

            #expect(
                GrokAccountExchange.shared.billingAuthorizations() == [
                    "Bearer first-access-token",
                    "Bearer second-access-token"
                ]
            )
            #expect(GrokAccountExchange.shared.tokenRequests() == 0)
        }
    }

    @Test(arguments: [500, 429])
    func transientFailureStopsAfterFirstAccount(
        status: Int
    ) async throws {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: [],
            billingStatus: status
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "oidc_client_id": "grok-client"
                ]
            )

            let failure = await GrokAccountFixture.failure {
                _ = try await GrokAccountFixture.provider(home: home)
                    .fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError
                    == .requestFailed(.grok, status)
            )
            #expect(
                GrokAccountExchange.shared.billingAuthorizations()
                    == ["Bearer first-access-token"]
            )
            #expect(
                !String(describing: failure)
                    .contains("first-access-token")
            )
        }
    }

    @Test
    func malformedPayloadStopsAfterFirstAccount() async throws {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: ["first-access-token"],
            malformedBilling: true
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "oidc_client_id": "grok-client"
                ]
            )

            let failure = await GrokAccountFixture.failure {
                _ = try await GrokAccountFixture.provider(home: home)
                    .fetch(now: Self.now)
            }

            #expect(failure != nil)
            #expect(
                GrokAccountExchange.shared.billingAuthorizations()
                    == ["Bearer first-access-token"]
            )
        }
    }

    @Test
    func cancellationStopsAfterFirstAccount() async throws {
        let started = GrokAccountExchange.shared.reset(
            acceptedUsageTokens: [],
            hangs: true
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "oidc_client_id": "grok-client"
                ]
            )
            let provider = GrokAccountFixture.provider(home: home)
            let task = Task { try await provider.fetch(now: Self.now) }

            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            task.cancel()
            let failure = await GrokAccountFixture.failure {
                _ = try await task.value
            }

            #expect(failure is CancellationError)
            #expect(
                GrokAccountExchange.shared.billingAuthorizations()
                    == ["Bearer first-access-token"]
            )
        }
    }

    @Test
    func persistsRotatedIDTokenPreservingUnknownFields() async throws {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: ["fresh-access-token"],
            rotatedIDToken: "rotated-id-token"
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "refresh_token": "first-refresh",
                    "oidc_client_id": "grok-client",
                    "id_token": "stored-id-token",
                    "unknown_field": "keep-me",
                    "expires_at": 1_785_600_000
                ]
            )

            _ = try await GrokAccountFixture.provider(home: home)
                .fetch(now: Self.now)

            let stored = try GrokAccountFixture.readAccounts(home: home)
            let first = try #require(stored["a-first"])
            #expect(first["key"] as? String == "fresh-access-token")
            #expect(
                first["refresh_token"] as? String
                    == "rotated-refresh-token"
            )
            #expect(first["id_token"] as? String == "rotated-id-token")
            #expect(first["unknown_field"] as? String == "keep-me")
            #expect(stored["b-second"] != nil)
        }
    }

    @Test
    func preservesStoredIDTokenWhenResponseOmitsIt() async throws {
        GrokAccountExchange.shared.reset(
            acceptedUsageTokens: ["fresh-access-token"]
        )
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "refresh_token": "first-refresh",
                    "oidc_client_id": "grok-client",
                    "id_token": "stored-id-token",
                    "expires_at": 1_785_600_000
                ]
            )

            _ = try await GrokAccountFixture.provider(home: home)
                .fetch(now: Self.now)

            let stored = try GrokAccountFixture.readAccounts(home: home)
            let first = try #require(stored["a-first"])
            #expect(first["id_token"] as? String == "stored-id-token")
        }
    }

    @Test
    func exhaustedAccountsReportLastActionableAuthError() async throws {
        GrokAccountExchange.shared.reset(acceptedUsageTokens: [])
        try await GrokAccountFixture.withDirectory { home in
            try GrokAccountFixture.writeAccounts(
                home: home,
                first: [
                    "key": "first-access-token",
                    "oidc_client_id": "grok-client"
                ]
            )

            let failure = await GrokAccountFixture.failure {
                _ = try await GrokAccountFixture.provider(home: home)
                    .fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError
                    == .authenticationRequired(.grok)
            )
            #expect(
                GrokAccountExchange.shared.billingAuthorizations() == [
                    "Bearer first-access-token",
                    "Bearer second-access-token"
                ]
            )
        }
    }
}

private enum GrokAccountFixture {
    static func provider(home: URL) -> GrokUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokAccountURLProtocol.self]
        return GrokUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: "missing-claude.json"),
                    codex: home.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: HephaestusGrokReliabilityKeychain(),
                homeDirectory: home,
                commandPaths: []
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration),
                retryPolicy: ProviderRetryPolicy(maximumAttempts: 1)
            )
        )
    }

    static func writeAccounts(
        home: URL,
        first: [String: Any]
    ) throws {
        let auth = home.appending(path: ".grok/auth.json")
        try FileManager.default.createDirectory(
            at: auth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: [
                "a-first": first,
                "b-second": [
                    "key": "second-access-token",
                    "oidc_client_id": "grok-client"
                ]
            ]
        ).write(to: auth)
    }

    static func readAccounts(
        home: URL
    ) throws -> [String: [String: Any]] {
        let data = try Data(
            contentsOf: home.appending(path: ".grok/auth.json")
        )
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any])?.compactMapValues {
            $0 as? [String: Any]
        } ?? [:]
    }

    static func failure(
        _ body: () async throws -> Void
    ) async -> (any Error)? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    static func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "GrokMultiAccount-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private final class GrokAccountExchange: @unchecked Sendable {
    static let shared = GrokAccountExchange()

    private let lock = NSLock()
    private var accepted: Set<String> = []
    private var refreshFailures: Set<String> = []
    private var billingStatus = 200
    private var malformed = false
    private var hangs = false
    private var rotatedIDToken: String?
    private var billing: [String] = []
    private var tokens = 0
    private var continuation: AsyncStream<Void>.Continuation?

    @discardableResult
    func reset(
        acceptedUsageTokens: Set<String>,
        refreshFailureTokens: Set<String> = [],
        billingStatus: Int = 200,
        malformedBilling: Bool = false,
        hangs: Bool = false,
        rotatedIDToken: String? = nil
    ) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            accepted = acceptedUsageTokens
            refreshFailures = refreshFailureTokens
            self.billingStatus = billingStatus
            malformed = malformedBilling
            self.hangs = hangs
            self.rotatedIDToken = rotatedIDToken
            billing = []
            tokens = 0
            self.continuation = continuation
        }
        return stream
    }

    /// `nil` means hang so the caller can observe cancellation.
    func recordBilling(authorization: String?) -> (Int, Bool)? {
        let signal: AsyncStream<Void>.Continuation?
        let outcome: (Int, Bool)?
        (signal, outcome) = lock.withLock {
            billing.append(authorization ?? "")
            guard !hangs else {
                return (continuation, nil)
            }
            guard billingStatus == 200 else {
                return (continuation, (billingStatus, false))
            }
            guard
                let authorization,
                accepted.contains(
                    String(authorization.dropFirst("Bearer ".count))
                )
            else {
                return (continuation, (401, false))
            }
            return (continuation, (200, malformed))
        }
        signal?.yield()
        return outcome
    }

    func recordToken(form: String) -> (Int, String?) {
        lock.withLock {
            tokens += 1
            let failed = refreshFailures.contains {
                form.contains("refresh_token=\($0)")
            }
            return (failed ? 401 : 200, failed ? nil : rotatedIDToken)
        }
    }

    func billingAuthorizations() -> [String] {
        lock.withLock { billing }
    }

    func tokenRequests() -> Int {
        lock.withLock { tokens }
    }
}

private final class GrokAccountURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/.well-known/openid-configuration" {
            respond(
                url: url,
                status: 200,
                body: """
                {"token_endpoint":"https://auth.grok.com/oauth/token"}
                """
            )
            return
        }
        if url.path.hasSuffix("token") {
            let (status, idToken) = GrokAccountExchange.shared.recordToken(
                form: requestBodyData(request).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? ""
            )
            guard status == 200 else {
                respond(
                    url: url,
                    status: status,
                    body: #"{"error":"invalid_grant"}"#
                )
                return
            }
            var payload: [String: Any] = [
                "access_token": "fresh-access-token",
                "refresh_token": "rotated-refresh-token",
                "expires_in": 3_600
            ]
            if let idToken {
                payload["id_token"] = idToken
            }
            respond(
                url: url,
                status: 200,
                body: String(
                    data: (
                        try? JSONSerialization.data(
                            withJSONObject: payload
                        )
                    ) ?? Data(),
                    encoding: .utf8
                ) ?? "{}"
            )
            return
        }
        if url.path == "/v1/settings" {
            respond(
                url: url,
                status: 200,
                body: #"{"planName":"SuperGrok"}"#
            )
            return
        }
        guard
            let (status, malformed) = GrokAccountExchange.shared
                .recordBilling(
                    authorization: request.value(
                        forHTTPHeaderField: "Authorization"
                    )
                )
        else {
            return
        }
        respond(
            url: url,
            status: status,
            body: malformed
                ? "{not-json"
                : """
                {
                  "weekly": {
                    "usedPercent": 91,
                    "resetAt": "2030-01-01T00:00:00Z"
                  }
                }
                """
        )
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, body: String) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private enum GrokRefreshFixture {
    static func provider(home: URL) -> GrokUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokRefreshURLProtocol.self]
        return GrokUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: "missing-claude.json"),
                    codex: home.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: HephaestusGrokReliabilityKeychain(),
                homeDirectory: home,
                commandPaths: []
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration),
                retryPolicy: ProviderRetryPolicy(maximumAttempts: 1)
            )
        )
    }

    static func writeCredential(
        home: URL,
        refreshToken: String = "grok-refresh-credential",
        expiresAt: Double,
        issuer: String?,
        clientID: String?
    ) throws {
        let auth = home.appending(path: ".grok/auth.json")
        try FileManager.default.createDirectory(
            at: auth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var entry: [String: Any] = [
            "key": "stored-access-token",
            "refresh_token": refreshToken,
            "expires_at": expiresAt
        ]
        entry["oidc_issuer"] = issuer
        entry["oidc_client_id"] = clientID
        try JSONSerialization.data(
            withJSONObject: ["account": entry]
        ).write(to: auth)
    }

    static func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "GrokRefreshContract-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private final class GrokRefreshExchange: @unchecked Sendable {
    static let shared = GrokRefreshExchange()

    private let lock = NSLock()
    private var tokenURLList: [String] = []
    private var forms: [String] = []
    private var authorizations: [String] = []

    func reset() {
        lock.withLock {
            tokenURLList = []
            forms = []
            authorizations = []
        }
    }

    func recordToken(url: String, form: String) {
        lock.withLock {
            tokenURLList.append(url)
            forms.append(form)
        }
    }

    func recordUsage(authorization: String?) {
        lock.withLock { authorizations.append(authorization ?? "") }
    }

    func tokenRequests() -> Int {
        lock.withLock { tokenURLList.count }
    }

    func tokenURLs() -> [String] {
        lock.withLock { tokenURLList }
    }

    func lastForm() -> String? {
        lock.withLock { forms.last }
    }

    func usageAuthorizations() -> [String] {
        lock.withLock { Array(Set(authorizations)).sorted() }
    }
}

private final class GrokRefreshURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/.well-known/openid-configuration" {
            respond(
                url: url,
                body: """
                {"token_endpoint":"https://auth.grok.com/oauth/token"}
                """
            )
            return
        }
        if url.path.hasSuffix("token") {
            GrokRefreshExchange.shared.recordToken(
                url: url.absoluteString,
                form: requestBodyData(request).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? ""
            )
            respond(
                url: url,
                body: """
                {
                  "access_token": "fresh-access-token",
                  "refresh_token": "rotated-refresh-token",
                  "expires_in": 3600
                }
                """
            )
            return
        }
        GrokRefreshExchange.shared.recordUsage(
            authorization: request.value(
                forHTTPHeaderField: "Authorization"
            )
        )
        if url.path == "/v1/settings" {
            respond(url: url, body: #"{"planName":"SuperGrok"}"#)
            return
        }
        respond(
            url: url,
            body: """
            {
              "weekly": {
                "usedPercent": 91,
                "resetAt": "2030-01-01T00:00:00Z"
              }
            }
            """
        )
    }

    override func stopLoading() {}

    private func respond(url: URL, body: String) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private enum HephaestusGrokReliabilityFixture {
    static func provider(home: URL) -> GrokUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HephaestusGrokReliabilityURLProtocol.self
        ]
        return GrokUsageProvider(
            discovery: discovery(home: home),
            http: ProviderHTTP(
                session: URLSession(configuration: configuration)
            )
        )
    }

    static func discovery(home: URL) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: HephaestusGrokReliabilityKeychain(),
            homeDirectory: home,
            commandPaths: []
        )
    }

    static func writeCredential(
        home: URL,
        accessToken: String = "grok-reliability-access-token",
        refreshToken: String? = nil,
        issuer: String? = nil,
        clientID: String? = nil
    ) throws {
        let auth = home.appending(path: ".grok/auth.json")
        try FileManager.default.createDirectory(
            at: auth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var entry = ["key": accessToken]
        entry["refresh_token"] = refreshToken
        entry["oidc_issuer"] = issuer
        entry["oidc_client_id"] = clientID
        let data = try JSONSerialization.data(
            withJSONObject: ["account": entry]
        )
        try data.write(to: auth)
    }

    static func integer(in text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.filter(\.isNumber)
        return Int(digits)
    }

    static func withDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusGrokReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusGrokReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private struct HephaestusGrokReliabilityKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class HephaestusGrokReliabilityURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cli-chat-proxy.grok.com"
            || request.url?.host == "auth.grok.com"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        if url.host == "auth.grok.com" {
            if url.path == "/.well-known/openid-configuration" {
                #expect(request.httpMethod == "GET")
            } else {
                #expect(url.path == "/oauth/token")
                #expect(request.httpMethod == "POST")
                #expect(
                    request.value(forHTTPHeaderField: "Content-Type")
                        == "application/x-www-form-urlencoded"
                )
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/json"
                )
                let form = requestBodyData(request).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? ""
                #expect(form.contains("grant_type=refresh_token"))
                #expect(
                    form.contains(
                        "refresh_token=grok-refresh-credential"
                    )
                )
                #expect(form.contains("client_id=grok-client"))
            }
        } else {
            #expect(
                url.absoluteString
                    == "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
                    || url.absoluteString
                        == "https://cli-chat-proxy.grok.com/v1/settings"
            )
            #expect(request.httpMethod == "GET")
            let expectedToken = url.path == "/v1/settings"
                ? request.value(forHTTPHeaderField: "Authorization")
                : request.value(forHTTPHeaderField: "Authorization")
            #expect(
                expectedToken == "Bearer grok-reliability-access-token"
                    || expectedToken == "Bearer fresh-access-token"
                    || expectedToken == "Bearer rejected-access-token"
            )
            #expect(
                request.value(forHTTPHeaderField: "X-XAI-Token-Auth")
                    == "xai-grok-cli"
            )
            #expect(
                request.value(forHTTPHeaderField: "Accept")
                    == "application/json"
            )
        }
        if
            url.path == "/v1/billing",
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer rejected-access-token"
        {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: Data(#"{"error":"expired"}"#.utf8)
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: String
        if url.path == "/.well-known/openid-configuration" {
            body = """
            {"token_endpoint":"https://auth.grok.com/oauth/token"}
            """
        } else if url.path == "/oauth/token" {
            body = """
            {
              "access_token": "fresh-access-token",
              "refresh_token": "rotated-refresh-token",
              "expires_in": 3600
            }
            """
        } else if url.path == "/v1/settings" {
            body = """
            {
              "planName": "LegacyPlan",
              "subscription_tier_display": "SuperGrok"
            }
            """
        } else {
            body = """
            {
              "weekly": {
                "usedPercent": 91,
                "resetAt": "2030-01-01T00:00:00Z"
              },
              "payAsYouGo": {"monthlyCap": 7},
              "config": {
                "creditUsagePercent": 37,
                "currentPeriod": {"end": "2026-09-01T00:00:00Z"},
                "onDemandCap": {"val": 2500}
              }
            }
            """
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
