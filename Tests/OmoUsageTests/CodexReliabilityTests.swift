import Foundation
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct CodexReliabilityTests {
    private let hephaestusNow = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func fiveHourOnlyPayloadIsNotReportedAsWeeklyUsage() {
        let payload = Data(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 37,
                  "limit_window_seconds": 18000,
                  "reset_at": 1785675000
                }
              }
            }
            """.utf8
        )

        #expect(throws: UsageParsingError.invalidPayload) {
            try CodexUsageParser.parse(payload, now: hephaestusNow)
        }
    }

    @Test
    func whamRequestUsesCurrentMethodURLAndCredentialHeaders() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            HephaestusCodexRequestRecorder.shared.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                HephaestusCodexURLProtocol.self
            ]
            let provider = CodexUsageProvider(
                discovery: CredentialDiscovery(
                    paths: CredentialPaths(
                        claude: directory.appending(path: "missing-claude.json"),
                        codex: directory.appending(path: "missing-codex.json")
                    ),
                    environment: [:],
                    keychain: HephaestusCodexKeychain(values: [
                        "Codex Auth\u{0}": """
                        {
                          "auth_mode": "chatgpt",
                          "tokens": {
                            "access_token": "hephaestus-access-token",
                            "account_id": "hephaestus-account-id"
                          }
                        }
                        """
                    ]),
                    homeDirectory: directory
                ),
                http: ProviderHTTP(
                    session: URLSession(configuration: configuration)
                )
            )

            _ = try await provider.fetch(now: hephaestusNow)

            let request = try #require(
                HephaestusCodexRequestRecorder.shared.snapshot()
            )
            #expect(request.method == "GET")
            #expect(
                request.url
                    == "https://chatgpt.com/backend-api/wham/usage"
            )
            #expect(request.authorization == "Bearer hephaestus-access-token")
            #expect(request.accountID == "hephaestus-account-id")
        }
    }

    @Test
    func malformedPreferredCodexFileFallsThroughToValidKeychainCandidate() throws {
        try hephaestusWithTemporaryDirectory { directory in
            let codexFile = directory.appending(path: "auth.json")
            try Data("{malformed".utf8).write(to: codexFile)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: codexFile
                ),
                environment: [:],
                keychain: HephaestusCodexKeychain(values: [
                    "Codex Auth\u{0}": """
                    {
                      "auth_mode": "chatgpt",
                      "tokens": {
                        "access_token": "hephaestus-keychain-token",
                        "account_id": "hephaestus-keychain-account"
                      }
                    }
                    """
                ]),
                homeDirectory: directory
            )

            let credential = try discovery.codex(now: hephaestusNow)

            #expect(credential.source == .keychain)
            #expect(credential.accessToken == "hephaestus-keychain-token")
            #expect(credential.accountID == "hephaestus-keychain-account")
        }
    }

    private func hephaestusWithTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusCodexReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func hephaestusWithTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusCodexReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private struct HephaestusCodexKeychain: KeychainReading {
    let values: [String: String]

    func value(service: String, account: String) throws -> String? {
        values["\(service)\u{0}\(account)"]
    }
}

private struct HephaestusCodexRecordedRequest: Sendable {
    let method: String?
    let url: String?
    let authorization: String?
    let accountID: String?
}

private final class HephaestusCodexRequestRecorder: @unchecked Sendable {
    static let shared = HephaestusCodexRequestRecorder()

    private let lock = NSLock()
    private var request: HephaestusCodexRecordedRequest?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        request = nil
    }

    func record(_ urlRequest: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        request = HephaestusCodexRecordedRequest(
            method: urlRequest.httpMethod,
            url: urlRequest.url?.absoluteString,
            authorization: urlRequest.value(
                forHTTPHeaderField: "Authorization"
            ),
            accountID: urlRequest.value(
                forHTTPHeaderField: "ChatGPT-Account-Id"
            )
        )
    }

    func snapshot() -> HephaestusCodexRecordedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class HephaestusCodexURLProtocol: URLProtocol,
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
        HephaestusCodexRequestRecorder.shared.record(request)
        let body = Data(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786100400
                }
              }
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
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

    override func stopLoading() {}
}
