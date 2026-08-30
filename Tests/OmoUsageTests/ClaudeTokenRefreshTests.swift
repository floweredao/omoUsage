import Foundation
import Testing
@testable import OmoUsage

/// Serialized: every case drives the same stubbed token exchange, so parallel
/// execution would let one scenario answer another's refresh request.
@Suite(.serialized)
struct ClaudeTokenRefreshTests {
    private static let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func expiredAccessTokenIsRefreshedBeforeUsageRequest() async throws {
        ClaudeRefreshExchange.shared.reset(
            tokenResponse: .success(
                accessToken: "rotated-access-token",
                refreshToken: "rotated-refresh-token",
                expiresIn: 3_600
            )
        )
        let writer = RecordingClaudeKeychainWriter()
        let provider = ClaudeRefreshFixtures.provider(writer: writer)

        let usage = try await provider.fetch(now: Self.now)

        #expect(usage.availability == .available)
        #expect(usage.planName == "Max 5x")
        #expect(
            usage.groups.flatMap(\.meters).map(\.percentRemaining)
                == [58, 75]
        )
        #expect(ClaudeRefreshExchange.shared.tokenRequestCount() == 1)
        #expect(
            ClaudeRefreshExchange.shared.usageAuthorizations()
                == ["Bearer rotated-access-token"]
        )
        let tokenRequest = try #require(
            ClaudeRefreshExchange.shared.lastTokenRequest()
        )
        #expect(
            tokenRequest.url
                == "https://platform.claude.com/v1/oauth/token"
        )
        #expect(tokenRequest.method == "POST")
        #expect(tokenRequest.body["grant_type"] as? String
            == "refresh_token")
        #expect(tokenRequest.body["refresh_token"] as? String
            == "stored-refresh-token")
        #expect(
            (tokenRequest.body["client_id"] as? String)?.isEmpty == false
        )
        // The token endpoint buckets unrecognised clients into a throttle
        // that answers 429 before it ever validates the grant; only the
        // claude-cli agent string is served normally.
        #expect(
            tokenRequest.userAgent == "claude-cli/2.1.220 (external, cli)"
        )
    }

    @Test
    func rotatedCredentialIsPersistedPreservingClaudeCodeFields() async throws {
        ClaudeRefreshExchange.shared.reset(
            tokenResponse: .success(
                accessToken: "rotated-access-token",
                refreshToken: "rotated-refresh-token",
                expiresIn: 3_600
            )
        )
        let writer = RecordingClaudeKeychainWriter()
        let provider = ClaudeRefreshFixtures.provider(writer: writer)
        // Deliberately sub-second: Claude Code stores expiresAt as whole
        // milliseconds, so the rewritten file must not gain a fraction.
        let now = Self.now.addingTimeInterval(0.5755)

        _ = try await provider.fetch(now: now)

        let write = try #require(writer.lastWrite())
        #expect(write.service == "Claude Code-credentials")
        #expect(write.account.isEmpty)
        let root = try #require(
            try JSONSerialization.jsonObject(
                with: Data(write.value.utf8)
            ) as? [String: Any]
        )
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "rotated-access-token")
        #expect(oauth["refreshToken"] as? String == "rotated-refresh-token")
        #expect(
            (oauth["expiresAt"] as? Double)
                == (
                    now.addingTimeInterval(3_600)
                        .timeIntervalSince1970 * 1_000
                ).rounded()
        )
        #expect(
            (oauth["expiresAt"] as? Double)?
                .truncatingRemainder(dividingBy: 1) == 0
        )
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(oauth["rateLimitTier"] as? String == "default_claude_max_5x")
        #expect(
            (oauth["scopes"] as? [String])
                == ["user:inference", "user:profile"]
        )
        #expect(
            (oauth["refreshTokenExpiresAt"] as? Double) == 4_102_444_800_000
        )
    }

    @Test
    func rejectedRefreshKeepsStoredCredentialAndDoesNotRetry() async throws {
        ClaudeRefreshExchange.shared.reset(
            tokenResponse: .failure(statusCode: 400)
        )
        let writer = RecordingClaudeKeychainWriter()
        let provider = ClaudeRefreshFixtures.provider(writer: writer)

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(now: Self.now)
        }

        #expect(writer.lastWrite() == nil)
        #expect(ClaudeRefreshExchange.shared.tokenRequestCount() == 1)
        #expect(ClaudeRefreshExchange.shared.usageAuthorizations() == [])
    }

    /// The dashboard refreshes every minute. Without a cooldown a rejected
    /// refresh is retried every minute forever, which is exactly how the
    /// token endpoint starts answering 429 to everything.
    @Test
    func failedRefreshIsNotRetriedOnEveryRefreshCycle() async throws {
        ClaudeRefreshExchange.shared.reset(
            tokenResponse: .failure(statusCode: 400)
        )
        let writer = RecordingClaudeKeychainWriter()
        let provider = ClaudeRefreshFixtures.provider(writer: writer)

        for offset in [0.0, 60.0, 120.0] {
            await #expect(throws: (any Error).self) {
                _ = try await provider.fetch(
                    now: Self.now.addingTimeInterval(offset)
                )
            }
        }

        #expect(ClaudeRefreshExchange.shared.tokenRequestCount() == 1)
    }

    @Test
    func refreshIsAttemptedAgainAfterTheCooldownElapses() async throws {
        ClaudeRefreshExchange.shared.reset(
            tokenResponse: .failure(statusCode: 400)
        )
        let writer = RecordingClaudeKeychainWriter()
        let provider = ClaudeRefreshFixtures.provider(writer: writer)

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(now: Self.now)
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(601)
            )
        }

        #expect(ClaudeRefreshExchange.shared.tokenRequestCount() == 2)
    }
}

private enum ClaudeRefreshFixtures {
    static let storedCredential = """
        {
          "claudeAiOauth": {
            "accessToken": "expired-access-token",
            "refreshToken": "stored-refresh-token",
            "expiresAt": 1785600000000,
            "refreshTokenExpiresAt": 4102444800000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_5x"
          }
        }
        """

    static let usageBody = Data(
        """
        {
          "five_hour": {"utilization": 42},
          "seven_day": {"utilization": 25}
        }
        """.utf8
    )

    static func provider(
        writer: RecordingClaudeKeychainWriter
    ) -> ClaudeUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeRefreshURLProtocol.self]
        let missing = URL(filePath: "/omo-claude-refresh/missing")
        return ClaudeUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(claude: missing, codex: missing),
                environment: [:],
                keychain: StoredClaudeKeychain(),
                keychainWriter: writer
            ),
            http: ProviderHTTP(
                session: URLSession(configuration: configuration)
            ),
            desktopUsageURL: missing,
            desktopSessionDiscovery: .unavailable,
            refreshCooldown: ClaudeRefreshCooldown()
        )
    }
}

private struct StoredClaudeKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        service == "Claude Code-credentials"
            ? ClaudeRefreshFixtures.storedCredential
            : nil
    }
}

final class RecordingClaudeKeychainWriter: KeychainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var write: (value: String, service: String, account: String)?

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        lock.withLock { write = (value, service, account) }
    }

    func lastWrite() -> (value: String, service: String, account: String)? {
        lock.withLock { write }
    }
}

private final class ClaudeRefreshExchange: @unchecked Sendable {
    enum TokenResponse {
        case success(
            accessToken: String,
            refreshToken: String,
            expiresIn: Double
        )
        case failure(statusCode: Int)
    }

    struct TokenRequest {
        let url: String
        let method: String
        let body: [String: Any]
        let userAgent: String?
    }

    static let shared = ClaudeRefreshExchange()

    private let lock = NSLock()
    private var response: TokenResponse = .failure(statusCode: 400)
    private var tokenRequests: [TokenRequest] = []
    private var authorizations: [String] = []

    func reset(tokenResponse: TokenResponse) {
        lock.withLock {
            response = tokenResponse
            tokenRequests = []
            authorizations = []
        }
    }

    func recordToken(_ request: TokenRequest) -> TokenResponse {
        lock.withLock {
            tokenRequests.append(request)
            return response
        }
    }

    func recordUsage(authorization: String?) {
        lock.withLock { authorizations.append(authorization ?? "") }
    }

    func tokenRequestCount() -> Int {
        lock.withLock { tokenRequests.count }
    }

    func lastTokenRequest() -> TokenRequest? {
        lock.withLock { tokenRequests.last }
    }

    func usageAuthorizations() -> [String] {
        lock.withLock { authorizations }
    }
}

private final class ClaudeRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            respond(statusCode: 500, body: Data())
            return
        }
        if url.path.hasSuffix("/oauth/token") {
            handleToken(url: url)
            return
        }
        let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        )
        ClaudeRefreshExchange.shared.recordUsage(
            authorization: authorization
        )
        guard authorization == "Bearer rotated-access-token" else {
            respond(statusCode: 401, body: Data())
            return
        }
        respond(
            statusCode: 200,
            body: ClaudeRefreshFixtures.usageBody
        )
    }

    override func stopLoading() {}

    private func handleToken(url: URL) {
        let body = requestBodyData(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let response = ClaudeRefreshExchange.shared.recordToken(
            ClaudeRefreshExchange.TokenRequest(
                url: url.absoluteString,
                method: request.httpMethod ?? "",
                body: body,
                userAgent: request.value(forHTTPHeaderField: "User-Agent")
            )
        )
        switch response {
        case let .success(accessToken, refreshToken, expiresIn):
            let payload: [String: Any] = [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "expires_in": expiresIn,
                "token_type": "Bearer"
            ]
            respond(
                statusCode: 200,
                body: (
                    try? JSONSerialization.data(withJSONObject: payload)
                ) ?? Data()
            )
        case let .failure(statusCode):
            respond(
                statusCode: statusCode,
                body: Data(#"{"error":"invalid_grant"}"#.utf8)
            )
        }
    }

    private func respond(statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
