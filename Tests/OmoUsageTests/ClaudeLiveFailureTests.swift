import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct ClaudeLiveFailureTests {
    @Test(arguments: [
        ClaudeDesktopSessionError.keychainUnavailable,
        ClaudeDesktopSessionError.cookiesUnavailable
    ])
    func missingClaudeLoginOffersConnectInsteadOfEndlessRetry(
        desktopError: ClaudeDesktopSessionError
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeMissingLogin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "missing.json")
        let provider = ClaudeUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(claude: missing, codex: missing),
                environment: [:],
                keychain: MissingClaudeLiveKeychain(),
                homeDirectory: directory
            ),
            desktopUsageURL: missing,
            desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                throw desktopError
            }
        )
        await #expect(throws: ProviderTransportError.authenticationRequired(.claude)) {
            _ = try await provider.fetch(
                now: Date(timeIntervalSince1970: 1_785_675_000)
            )
        }
    }

    @Test
    func liveSessionFailureNeverReturnsCachedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let historyURL = directory.appending(path: "plan-usage-history.json")
        try Data(
            """
            {
              "version": 2,
              "samples": [{
                "t": 1785653400000,
                "org": "test-organization",
                "u": {"fh": 1, "sd": 0}
              }]
            }
            """.utf8
        ).write(to: historyURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ClaudeFailureURLProtocol.self
        ]
        let provider = ClaudeUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: directory.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: MissingClaudeLiveKeychain(),
                homeDirectory: directory
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration)
            ),
            desktopUsageURL: historyURL,
            desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                ClaudeDesktopSession(
                    organizationID: "test-organization",
                    cookieHeader: "sessionKey=<redacted>"
                )
            }
        )

        let result: Result<ProviderUsage, Error>
        do {
            result = .success(
                try await provider.fetch(
                    now: Date(timeIntervalSince1970: 1_785_675_000)
                )
            )
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success:
            #expect(Bool(false))
        case let .failure(error):
            #expect(
                error as? ProviderTransportError
                    == .requestFailed(.claude, 503)
            )
        }
    }
}

/// Serialized: every case drives the same stubbed usage endpoint, so
/// parallel execution would let one scenario answer another's request.
@Suite(.serialized)
struct ClaudeUsageCooldownTests {
    private static let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func rateLimitedUsageSuppressesSecondFetchWithinCooldown()
        async throws
    {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 429)
        let provider = ClaudeUsageCooldownFixtures.provider()

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(now: Self.now)
        }
        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 1)

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(60)
            )
        }

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 1)
        #expect(ClaudeUsageCooldownExchange.shared.tokenRequests() == 0)
    }

    @Test
    func liveUsageIsCalledAgainAfterCooldownExpires() async throws {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 429)
        let provider = ClaudeUsageCooldownFixtures.provider()

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(now: Self.now)
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(300)
            )
        }

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 2)
    }

    @Test
    func rateLimitedUsageIsNotRetriedWithinOneRefresh() async throws {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 429)
        let provider = ClaudeUsageCooldownFixtures.provider(
            retryPolicy: ProviderRetryPolicy()
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(now: Self.now)
        }

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 1)
    }

    @Test
    func rateLimitWithLongRetryAfterStillArmsCooldown() async throws {
        ClaudeUsageCooldownExchange.shared.reset(
            usageStatus: 429,
            retryAfter: "60"
        )
        let provider = ClaudeUsageCooldownFixtures.provider(
            retryPolicy: ProviderRetryPolicy()
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(now: Self.now)
        }
        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(60)
            )
        }

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 1)
    }

    /// A server asking for a longer pause than the default must be obeyed;
    /// reading again at the default deadline extends the ban.
    @Test
    func longerRetryAfterExtendsUsageCooldown() async throws {
        ClaudeUsageCooldownExchange.shared.reset(
            usageStatus: 429,
            retryAfter: "900"
        )
        let provider = ClaudeUsageCooldownFixtures.provider()

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(now: Self.now)
        }
        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 429)
        ) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(600)
            )
        }
        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 1)

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(
                now: Self.now.addingTimeInterval(900)
            )
        }
        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 2)
    }

    @Test
    func successfulUsageDoesNotSuppressSubsequentFetch() async throws {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 200)
        let provider = ClaudeUsageCooldownFixtures.provider()

        _ = try await provider.fetch(now: Self.now)
        _ = try await provider.fetch(
            now: Self.now.addingTimeInterval(60)
        )

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 2)
    }

    @Test
    func successfulUsageClearsArmedCooldown() async throws {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 429)
        let cooldown = ClaudeUsageCooldown(interval: 300)
        let provider = ClaudeUsageCooldownFixtures.provider(
            usageCooldown: cooldown
        )
        let accountProviderID = AccountProviderID(
            accountID: provider.accountID,
            providerID: .claude
        )

        await #expect(throws: (any Error).self) {
            _ = try await provider.fetch(now: Self.now)
        }
        var allowsAttempt = await cooldown.allowsAttempt(
            for: accountProviderID,
            at: Self.now.addingTimeInterval(1)
        )
        #expect(allowsAttempt == false)

        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 200)
        _ = try await provider.fetch(
            now: Self.now.addingTimeInterval(300)
        )

        // Queried before the armed deadline: only a cleared entry, not an
        // elapsed one, allows an attempt back here.
        allowsAttempt = await cooldown.allowsAttempt(
            for: accountProviderID,
            at: Self.now.addingTimeInterval(1)
        )
        #expect(allowsAttempt == true)
    }

    @Test
    func rateLimitedAccountDoesNotSuppressAnotherAccount() async throws {
        ClaudeUsageCooldownExchange.shared.reset(usageStatus: 429)
        let first = ClaudeUsageCooldownFixtures.provider()
        let second = ClaudeUsageCooldownFixtures.provider()

        await #expect(throws: (any Error).self) {
            _ = try await first.fetch(now: Self.now)
        }
        await #expect(throws: (any Error).self) {
            _ = try await second.fetch(
                now: Self.now.addingTimeInterval(60)
            )
        }

        #expect(ClaudeUsageCooldownExchange.shared.usageRequests() == 2)
    }
}

private enum ClaudeUsageCooldownFixtures {
    static let storedCredential = """
        {
          "claudeAiOauth": {
            "accessToken": "cooldown-access-token",
            "refreshToken": "cooldown-refresh-token",
            "expiresAt": 1790000000000,
            "subscriptionType": "max"
          }
        }
        """

    static func provider(
        usageCooldown: ClaudeUsageCooldown = .shared,
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(
            maximumAttempts: 1
        )
    ) -> ClaudeUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ClaudeUsageCooldownURLProtocol.self
        ]
        let missing = URL(filePath: "/omo-claude-cooldown/missing")
        return ClaudeUsageProvider(
            accountID: AccountID(),
            discovery: CredentialDiscovery(
                paths: CredentialPaths(claude: missing, codex: missing),
                environment: [:],
                keychain: StoredClaudeCooldownKeychain(),
                providerKeychain: StoredClaudeCooldownKeychain()
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration),
                retryPolicy: retryPolicy
            ),
            desktopUsageURL: missing,
            desktopSessionDiscovery: .unavailable,
            refreshCooldown: ClaudeRefreshCooldown(),
            usageCooldown: usageCooldown
        )
    }
}

private struct StoredClaudeCooldownKeychain:
    KeychainReading,
    ProviderKeychain
{
    func value(service: String, account: String) throws -> String? {
        if service == ProviderAPIKeyStore.serviceName {
            return try CredentialSnapshot(
                provider: .claude,
                accessToken: "cooldown-access-token",
                refreshToken: "cooldown-refresh-token",
                accountReference: nil,
                planName: "Max",
                expiresAt: Date(timeIntervalSince1970: 1_790_000_000),
                source: .keychain
            ).encodedSecret()
        }
        return service == "Claude Code-credentials"
            ? ClaudeUsageCooldownFixtures.storedCredential
            : nil
    }

    func set(_ value: String, service: String, account: String) throws {}

    func remove(service: String, account: String) throws {}
}

private final class ClaudeUsageCooldownExchange: @unchecked Sendable {
    static let shared = ClaudeUsageCooldownExchange()

    private let lock = NSLock()
    private var status = 429
    private var retryAfter: String?
    private var usageCount = 0
    private var tokenCount = 0

    func reset(usageStatus: Int, retryAfter: String? = nil) {
        lock.withLock {
            status = usageStatus
            self.retryAfter = retryAfter
            usageCount = 0
            tokenCount = 0
        }
    }

    func recordUsage() -> (status: Int, retryAfter: String?) {
        lock.withLock {
            usageCount += 1
            return (status, retryAfter)
        }
    }

    func recordToken() {
        lock.withLock { tokenCount += 1 }
    }

    func usageRequests() -> Int {
        lock.withLock { usageCount }
    }

    func tokenRequests() -> Int {
        lock.withLock { tokenCount }
    }
}

private final class ClaudeUsageCooldownURLProtocol: URLProtocol,
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
            respond(statusCode: 500, body: Data())
            return
        }
        if url.path.hasSuffix("/oauth/token") {
            ClaudeUsageCooldownExchange.shared.recordToken()
            respond(statusCode: 400, body: Data())
            return
        }
        let usage = ClaudeUsageCooldownExchange.shared.recordUsage()
        respond(
            statusCode: usage.status,
            retryAfter: usage.retryAfter,
            body: Data(
                """
                {
                  "five_hour": {"utilization": 42},
                  "seven_day": {"utilization": 25}
                }
                """.utf8
            )
        )
    }

    override func stopLoading() {}

    private func respond(
        statusCode: Int,
        retryAfter: String? = nil,
        body: Data
    ) {
        var headers = ["Content-Type": "application/json"]
        headers["Retry-After"] = retryAfter
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
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

/// Serialized: every case drives the same stubbed usage endpoint, so
/// parallel execution would let one scenario answer another's request.
@Suite(.serialized)
struct ClaudeSourceFallbackTests {
    private static let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func rejectedKeychainCandidateFallsBackToFileCandidate()
        async throws
    {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: ["file-access"]
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                )
            )

            let usage = try await provider.fetch(now: Self.now)

            #expect(usage.availability == .available)
            #expect(
                ClaudeFallbackExchange.shared.authorizations() == [
                    "Bearer keychain-access",
                    "Bearer file-access"
                ]
            )
        }
    }

    @Test
    func expiredKeychainCandidateFailingRefreshFallsBackToFile()
        async throws
    {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: ["file-access"],
            tokenStatus: 401
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: "keychain-refresh",
                    expiresAtMilliseconds: 1_785_600_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                )
            )

            let usage = try await provider.fetch(now: Self.now)

            #expect(usage.availability == .available)
            #expect(ClaudeFallbackExchange.shared.tokenRequests() == 1)
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer file-access"]
            )
        }
    }

    @Test
    func environmentTokenIsAttemptedAfterEveryStoredCandidate()
        async throws
    {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: ["environment-access"]
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                environmentToken: "environment-access"
            )

            let usage = try await provider.fetch(now: Self.now)

            #expect(usage.availability == .available)
            #expect(
                ClaudeFallbackExchange.shared.authorizations() == [
                    "Bearer keychain-access",
                    "Bearer file-access",
                    "Bearer environment-access"
                ]
            )
        }
    }

    @Test
    func oauthServerFailureDoesNotUseDesktop() async throws {
        try await expectNonAuthenticationFailureDoesNotUseDesktop(
            .serverError
        )
    }

    @Test
    func oauthRateLimitDoesNotUseDesktop() async throws {
        try await expectNonAuthenticationFailureDoesNotUseDesktop(
            .rateLimited
        )
    }

    @Test
    func malformedOAuthPayloadDoesNotUseDesktop() async throws {
        try await expectNonAuthenticationFailureDoesNotUseDesktop(
            .invalidJSON
        )
    }

    @Test
    func rotatedTokenPersistenceFailureDoesNotUseDesktop() async throws {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: [],
            tokenStatus: 200,
            tokenSucceeds: true
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "expiring-keychain-access",
                    refreshToken: "expiring-keychain-refresh",
                    expiresAtMilliseconds: 1_785_675_240_000
                ),
                fileCredential: nil,
                desktopPresent: true,
                keychainWriter: ClaudeFallbackFailingWriter()
            )

            let failure = await ClaudeFallbackFixtures.failure {
                try await provider.fetch(now: Self.now)
            }

            #expect(failure is ClaudeFallbackFailingWriter.Failure)
            #expect(ClaudeFallbackExchange.shared.tokenRequests() == 1)
            #expect(ClaudeFallbackExchange.shared.authorizations().isEmpty)
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 0)
            let description = String(describing: failure)
            #expect(!description.contains("expiring-keychain-access"))
            #expect(!description.contains("expiring-keychain-refresh"))
            #expect(!description.contains("desktop-session-secret"))
        }
    }

    @Test
    func exhaustedOAuthAuthenticationMayUseDesktop() async throws {
        ClaudeFallbackExchange.shared.reset(acceptedUsageTokens: [])
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "desktop-keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "desktop-file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                desktopPresent: true
            )

            let usage = try await provider.fetch(now: Self.now)

            #expect(usage.availability == .available)
            #expect(
                ClaudeFallbackExchange.shared.authorizations() == [
                    "Bearer desktop-keychain-access",
                    "Bearer desktop-file-access"
                ]
            )
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 1)
        }
    }

    @Test
    func rejectedOAuthPreservesAuthenticationWhenDesktopDiscoveryFails()
        async throws
    {
        ClaudeFallbackExchange.shared.reset(acceptedUsageTokens: [])
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "rejected-oauth-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: nil,
                desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                    throw ClaudeFallbackDesktopDiscoveryFailure()
                }
            )

            let failure = await ClaudeFallbackFixtures.failure {
                _ = try await provider.fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError
                    == .authenticationRequired(.claude)
            )
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer rejected-oauth-access"]
            )
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 0)
        }
    }

    @Test
    func missingOAuthCredentialMayUseDesktop() async throws {
        ClaudeFallbackExchange.shared.reset(acceptedUsageTokens: [])
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: nil,
                fileCredential: nil,
                desktopPresent: true
            )

            let usage = try await provider.fetch(now: Self.now)

            #expect(usage.availability == .available)
            #expect(ClaudeFallbackExchange.shared.authorizations().isEmpty)
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 1)
        }
    }

    @Test
    func transientFailureDoesNotCrossFallBackToAnotherCandidate()
        async throws
    {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: [],
            usageStatus: 500
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                )
            )

            let failure = await ClaudeFallbackFixtures.failure {
                try await provider.fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError
                    == .requestFailed(.claude, 500)
            )
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer keychain-access"]
            )
            #expect(
                !String(describing: failure).contains("keychain-access")
            )
            #expect(
                !String(describing: failure).contains("file-access")
            )
        }
    }

    @Test
    func rateLimitedCandidateDoesNotCrossFallBack() async throws {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: [],
            usageStatus: 429
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                )
            )

            let failure = await ClaudeFallbackFixtures.failure {
                try await provider.fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError
                    == .requestFailed(.claude, 429)
            )
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer keychain-access"]
            )
        }
    }

    @Test
    func cancellationStopsBeforeTryingAnotherCandidate() async throws {
        let started = ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: [],
            hangs: true
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "file-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                desktopPresent: true
            )
            let task = Task { try await provider.fetch(now: Self.now) }

            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            task.cancel()
            let failure = await ClaudeFallbackFixtures.failure {
                try await task.value
            }

            #expect(failure is CancellationError)
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer keychain-access"]
            )
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 0)
        }
    }

    private func expectNonAuthenticationFailureDoesNotUseDesktop(
        _ scenario: ClaudeDesktopBoundaryFailure
    ) async throws {
        ClaudeFallbackExchange.shared.reset(
            acceptedUsageTokens: scenario == .invalidJSON
                ? ["boundary-keychain-access"]
                : [],
            usageStatus: scenario.status,
            invalidJSON: scenario == .invalidJSON
        )
        try await withFallbackHome { home in
            let provider = try ClaudeFallbackFixtures.provider(
                home: home,
                keychainCredential: ClaudeFallbackFixtures.credential(
                    accessToken: "boundary-keychain-access",
                    refreshToken: nil,
                    expiresAtMilliseconds: 1_790_000_000_000
                ),
                fileCredential: nil,
                desktopPresent: true
            )

            let failure = await ClaudeFallbackFixtures.failure {
                try await provider.fetch(now: Self.now)
            }

            #expect(
                failure as? ProviderTransportError == scenario.expected
            )
            #expect(
                ClaudeFallbackExchange.shared.authorizations()
                    == ["Bearer boundary-keychain-access"]
            )
            #expect(ClaudeFallbackExchange.shared.desktopRequests() == 0)
            let description = String(describing: failure)
            #expect(!description.contains("boundary-keychain-access"))
            #expect(!description.contains("desktop-session-secret"))
        }
    }

    private enum ClaudeDesktopBoundaryFailure: String, Sendable {
        case serverError
        case rateLimited
        case invalidJSON

        var status: Int {
            switch self {
            case .serverError: 500
            case .rateLimited: 429
            case .invalidJSON: 200
            }
        }

        var expected: ProviderTransportError {
            switch self {
            case .serverError:
                .requestFailed(.claude, 500)
            case .rateLimited:
                .requestFailed(.claude, 429)
            case .invalidJSON:
                .invalidJSON(.claude)
            }
        }
    }

    private func withFallbackHome(
        _ body: (URL) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageClaudeFallback-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try await body(home)
    }
}

private enum ClaudeFallbackFixtures {
    static func credential(
        accessToken: String,
        refreshToken: String?,
        expiresAtMilliseconds: Int
    ) -> String {
        var fields = ["\"accessToken\": \"\(accessToken)\""]
        if let refreshToken {
            fields.append("\"refreshToken\": \"\(refreshToken)\"")
        }
        fields.append("\"expiresAt\": \(expiresAtMilliseconds)")
        fields.append("\"subscriptionType\": \"max\"")
        return """
        {"claudeAiOauth": {\(fields.joined(separator: ", "))}}
        """
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

    static func provider(
        home: URL,
        keychainCredential: String?,
        fileCredential: String?,
        environmentToken: String? = nil,
        desktopPresent: Bool = false,
        desktopSessionDiscovery: ClaudeDesktopSessionDiscovery? = nil,
        keychainWriter: (any KeychainWriting)? = nil
    ) throws -> ClaudeUsageProvider {
        let claudeURL = home.appending(path: "credentials.json")
        if let fileCredential {
            try Data(fileCredential.utf8).write(to: claudeURL)
        }
        var environment: [String: String] = [:]
        if let environmentToken {
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = environmentToken
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeFallbackURLProtocol.self]
        return ClaudeUsageProvider(
            accountID: .legacy,
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: claudeURL,
                    codex: home.appending(path: "codex.json")
                ),
                environment: environment,
                keychain: ClaudeFallbackKeychain(
                    credential: keychainCredential
                ),
                keychainWriter: keychainWriter,
                homeDirectory: home
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration),
                retryPolicy: ProviderRetryPolicy(maximumAttempts: 1)
            ),
            desktopUsageURL: home.appending(path: "missing-history.json"),
            desktopSessionDiscovery: desktopSessionDiscovery
                ?? ClaudeDesktopSessionDiscovery {
                    desktopPresent
                        ? ClaudeDesktopSession(
                            organizationID: "desktop-organization",
                            cookieHeader:
                                "sessionKey=desktop-session-secret"
                        )
                        : nil
                },
            refreshCooldown: ClaudeRefreshCooldown(),
            usageCooldown: ClaudeUsageCooldown()
        )
    }
}

private struct ClaudeFallbackDesktopDiscoveryFailure: Error {}

private struct ClaudeFallbackFailingWriter: KeychainWriting {
    struct Failure: Error {}

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        throw Failure()
    }
}

private struct ClaudeFallbackKeychain: KeychainReading {
    let credential: String?

    func value(service: String, account: String) throws -> String? {
        service == "Claude Code-credentials" ? credential : nil
    }
}

private final class ClaudeFallbackExchange: @unchecked Sendable {
    static let shared = ClaudeFallbackExchange()

    private let lock = NSLock()
    private var accepted: Set<String> = []
    private var usageStatus = 200
    private var tokenStatus = 401
    private var hangs = false
    private var invalidJSON = false
    private var tokenSucceeds = false
    private var recorded: [String] = []
    private var tokenCount = 0
    private var desktopCount = 0
    private var continuation: AsyncStream<Void>.Continuation?

    @discardableResult
    func reset(
        acceptedUsageTokens: Set<String>,
        usageStatus: Int = 200,
        tokenStatus: Int = 401,
        hangs: Bool = false,
        invalidJSON: Bool = false,
        tokenSucceeds: Bool = false
    ) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            accepted = acceptedUsageTokens
            self.usageStatus = usageStatus
            self.tokenStatus = tokenStatus
            self.hangs = hangs
            self.invalidJSON = invalidJSON
            self.tokenSucceeds = tokenSucceeds
            recorded = []
            tokenCount = 0
            desktopCount = 0
            self.continuation = continuation
        }
        return stream
    }

    /// Returns the status the stub should answer, or `nil` to hang so the
    /// caller can observe cancellation instead of a response.
    func recordUsage(authorization: String?) -> Int? {
        let signal: AsyncStream<Void>.Continuation?
        let status: Int?
        (signal, status) = lock.withLock {
            recorded.append(authorization ?? "")
            guard !hangs else {
                return (continuation, nil)
            }
            guard
                let authorization,
                authorization.hasPrefix("Bearer "),
                accepted.contains(
                    String(authorization.dropFirst("Bearer ".count))
                )
            else {
                return (continuation, usageStatus == 200 ? 401 : usageStatus)
            }
            return (continuation, 200)
        }
        signal?.yield()
        return status
    }

    func recordToken() -> (status: Int, succeeds: Bool) {
        lock.withLock {
            tokenCount += 1
            return (tokenStatus, tokenSucceeds)
        }
    }

    func usageBody() -> Data {
        lock.withLock {
            invalidJSON
                ? Data("{".utf8)
                : Data(
                    """
                    {
                      "five_hour": {"utilization": 42},
                      "seven_day": {"utilization": 25}
                    }
                    """.utf8
                )
        }
    }

    func recordDesktop() {
        lock.withLock { desktopCount += 1 }
    }

    func desktopRequests() -> Int {
        lock.withLock { desktopCount }
    }

    func authorizations() -> [String] {
        lock.withLock { recorded }
    }

    func tokenRequests() -> Int {
        lock.withLock { tokenCount }
    }
}

private final class ClaudeFallbackURLProtocol: URLProtocol,
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
            respond(statusCode: 500, body: Data())
            return
        }
        if url.host == "claude.ai" {
            ClaudeFallbackExchange.shared.recordDesktop()
            respond(
                statusCode: 200,
                body: ClaudeFallbackExchange.shared.usageBody()
            )
            return
        }
        if url.path.hasSuffix("/oauth/token") {
            let token = ClaudeFallbackExchange.shared.recordToken()
            respond(
                statusCode: token.status,
                body: token.succeeds
                    ? Data(
                        #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8
                    )
                    : Data(#"{"error":"invalid_grant"}"#.utf8)
            )
            return
        }
        guard
            let status = ClaudeFallbackExchange.shared.recordUsage(
                authorization: request.value(
                    forHTTPHeaderField: "Authorization"
                )
            )
        else {
            return
        }
        respond(
            statusCode: status,
            body: ClaudeFallbackExchange.shared.usageBody()
        )
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
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

private struct MissingClaudeLiveKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class ClaudeFailureURLProtocol: URLProtocol,
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
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
