import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ClaudeLiveFailureTests {
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
