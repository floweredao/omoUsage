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
