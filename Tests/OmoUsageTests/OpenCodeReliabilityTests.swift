import Foundation
import Testing
@testable import OmoUsage

@Suite
struct OpenCodeReliabilityTests {
    @Test
    func mapsOfficialGoUsageWindowsToRemainingPercentAndReset() async throws {
        try await HephaestusOpenCodeReliabilityFixture.withDirectory { home in
            try HephaestusOpenCodeReliabilityFixture.writeGoCredential(
                home: home
            )
            let now = Date(timeIntervalSince1970: 1_786_809_600)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                HephaestusOpenCodeReliabilityURLProtocol.self
            ]
            let usage = try await OpenCodeUsageProvider(
                discovery: HephaestusOpenCodeReliabilityFixture.discovery(
                    home: home
                ),
                http: ProviderHTTP(
                    session: URLSession(configuration: configuration)
                )
            ).fetch(now: now)

            #expect(usage.provider == .opencode)
            #expect(usage.planName == "Go")
            #expect(usage.updatedAt == now)
            let meters = usage.groups.flatMap(\.meters)
            #expect(meters.map(\.period) == [.session, .week, .extra])
            #expect(meters.map(\.percentRemaining) == [80, 60, 40])
            #expect(meters.map(\.resetsAt) == [
                Date(timeIntervalSince1970: 1_786_824_000),
                Date(timeIntervalSince1970: 1_787_212_800),
                Date(timeIntervalSince1970: 1_788_220_800)
            ])
        }
    }

    @Test
    func setupTargetsOpenCodeGoAuthentication() throws {
        let descriptor = try #require(
            ProviderSetup.descriptor(for: .opencode)
        )

        #expect(descriptor.action == .apiKey)
        #expect(descriptor.acceptsAPIKey)
    }
}

private enum HephaestusOpenCodeReliabilityFixture {
    static func discovery(home: URL) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: HephaestusOpenCodeReliabilityKeychain(),
            homeDirectory: home,
            commandPaths: []
        )
    }

    static func writeGoCredential(home: URL) throws {
        let auth = home.appending(
            path: ".local/share/opencode/auth.json"
        )
        try FileManager.default.createDirectory(
            at: auth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "opencode-go": ["key": "opencode-reliability-token"]
            ]
        )
        try data.write(to: auth)
    }

    static func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusOpenCodeReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private struct HephaestusOpenCodeReliabilityKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class HephaestusOpenCodeReliabilityURLProtocol:
    URLProtocol,
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
        #expect(
            request.url?.absoluteString
                == "https://opencode.ai/zen/go/v1/usage"
        )
        #expect(request.httpMethod == "GET")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer opencode-reliability-token"
        )
        let body = Data(
            """
            {
              "usage": {
                "rolling": {
                  "percent": 20,
                  "resetsAt": 1786824000
                },
                "weekly": {
                  "percent": 40,
                  "resetsAt": 1787212800
                },
                "monthly": {
                  "percent": 60,
                  "resetsAt": 1788220800
                }
              }
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
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

    override func stopLoading() {}
}
