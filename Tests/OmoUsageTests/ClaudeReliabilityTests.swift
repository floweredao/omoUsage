import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ClaudeReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func malformedPreferredCredentialFallsThroughToValidFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "HephaestusClaudeReliability-Credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let claudeURL = directory.appending(path: "credentials.json")
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "later-candidate-token",
                "expiresAt": 4102444800000
              }
            }
            """.utf8
        ).write(to: claudeURL)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: claudeURL,
                codex: directory.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: HephaestusMalformedClaudeKeychain()
        )

        let credential = try discovery.claude(now: now)

        #expect(credential.source == .file)
        #expect(credential.accessToken == "later-candidate-token")
    }

    @Test
    func oauthUsageRequestIncludesRequiredHeaders() async throws {
        HephaestusOAuthHeaderRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HephaestusOAuthHeaderURLProtocol.self]
        let provider = ClaudeUsageProvider(
            discovery: HephaestusClaudeReliabilityFixtures.discovery(
                environment: ["CLAUDE_CODE_OAUTH_TOKEN": "header-test-token"]
            ),
            http: ProviderHTTP(
                session: URLSession(configuration: configuration)
            ),
            desktopSessionDiscovery: .unavailable
        )

        _ = try await provider.fetch(now: now)
        let headers = try #require(
            HephaestusOAuthHeaderRecorder.shared.recordedHeaders()
        )

        #expect(
            headers.url
                == "https://api.anthropic.com/api/oauth/usage"
                    + "?cedar_ember=1&skip_spend=1"
        )
        #expect(headers.method == "GET")
        #expect(headers.authorization == "Bearer header-test-token")
        #expect(headers.accept == "application/json")
        #expect(headers.beta == "oauth-2025-04-20")
        #expect(headers.contentType == "application/json")
        #expect(headers.userAgent == "claude-code/2.1.69")
    }

    @Test
    func transientOAuthFailureDoesNotCrossDesktopSession() async throws {
        HephaestusTransientFallbackRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HephaestusTransientFallbackURLProtocol.self]
        let provider = ClaudeUsageProvider(
            discovery: HephaestusClaudeReliabilityFixtures.discovery(
                environment: ["CLAUDE_CODE_OAUTH_TOKEN": "transient-test-token"]
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration),
                retryPolicy: ProviderRetryPolicy(maximumAttempts: 1)
            ),
            desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                ClaudeDesktopSession(
                    organizationID: "fixture-organization",
                    cookieHeader: "sessionKey=fixture-session"
                )
            }
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 503)
        ) {
            try await provider.fetch(now: now)
        }
        #expect(
            HephaestusTransientFallbackRecorder.shared.requestedHosts()
                == ["api.anthropic.com"]
        )
    }
}

private enum HephaestusClaudeReliabilityFixtures {
    static func discovery(
        environment: [String: String]
    ) -> CredentialDiscovery {
        let missing = URL(filePath: "/hephaestus-claude-reliability/missing")
        return CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: environment,
            keychain: HephaestusMissingClaudeKeychain()
        )
    }

    static let usageBody = Data(
        """
        {
          "five_hour": {"utilization": 42},
          "seven_day": {"utilization": 25}
        }
        """.utf8
    )
}

private struct HephaestusMalformedClaudeKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        "{malformed"
    }
}

private struct HephaestusMissingClaudeKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class HephaestusOAuthHeaderRecorder: @unchecked Sendable {
    static let shared = HephaestusOAuthHeaderRecorder()

    private let lock = NSLock()
    private var headers: (
        url: String?,
        method: String?,
        authorization: String?,
        accept: String?,
        beta: String?,
        contentType: String?,
        userAgent: String?
    )?

    func reset() {
        lock.withLock { headers = nil }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            headers = (
                request.url?.absoluteString,
                request.httpMethod,
                request.value(forHTTPHeaderField: "Authorization"),
                request.value(forHTTPHeaderField: "Accept"),
                request.value(forHTTPHeaderField: "anthropic-beta"),
                request.value(forHTTPHeaderField: "Content-Type"),
                request.value(forHTTPHeaderField: "User-Agent")
            )
        }
    }

    func recordedHeaders() -> (
        url: String?,
        method: String?,
        authorization: String?,
        accept: String?,
        beta: String?,
        contentType: String?,
        userAgent: String?
    )? {
        lock.withLock { headers }
    }
}

private final class HephaestusOAuthHeaderURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        HephaestusOAuthHeaderRecorder.shared.record(request)
        respond(
            statusCode: 200,
            body: HephaestusClaudeReliabilityFixtures.usageBody
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

private final class HephaestusTransientFallbackRecorder: @unchecked Sendable {
    static let shared = HephaestusTransientFallbackRecorder()

    private let lock = NSLock()
    private var hosts: [String] = []

    func reset() {
        lock.withLock { hosts = [] }
    }

    func record(host: String?) {
        lock.withLock { hosts.append(host ?? "") }
    }

    func requestedHosts() -> [String] {
        lock.withLock { hosts }
    }
}

private final class HephaestusTransientFallbackURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host
        HephaestusTransientFallbackRecorder.shared.record(host: host)
        if host == "api.anthropic.com" {
            respond(statusCode: 503, body: Data())
        } else {
            respond(
                statusCode: 200,
                body: HephaestusClaudeReliabilityFixtures.usageBody
            )
        }
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
