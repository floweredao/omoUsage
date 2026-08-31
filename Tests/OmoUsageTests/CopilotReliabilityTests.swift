import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct CopilotReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func paidPlanWithoutQuotaFieldsRemainsAvailable() async throws {
        let usage = try await CopilotReliabilityFixture.fetch(
            protocolClass: CopilotReliabilityPlanOnlyURLProtocol.self,
            now: now
        )

        #expect(usage.provider == .copilot)
        #expect(usage.planName == "Individual")
        #expect(usage.availability == .available)
        #expect(usage.groups.isEmpty)
    }

    @Test
    func freePlanMapsLimitedAndMonthlyQuotas() async throws {
        let usage = try await CopilotReliabilityFixture.fetch(
            protocolClass: CopilotReliabilityFreeQuotaURLProtocol.self,
            now: now
        )
        let percentages = Dictionary(
            uniqueKeysWithValues: usage.groups
                .flatMap(\.meters)
                .map { ($0.id, $0.percentRemaining) }
        )

        #expect(usage.planName == "Free")
        #expect(percentages == [
            "copilot-chat": 60,
            "copilot-completions": 50
        ])
    }

    @Test
    func unlimitedBucketsAreSuppressed() async throws {
        let usage = try await CopilotReliabilityFixture.fetch(
            protocolClass: CopilotReliabilityUnlimitedURLProtocol.self,
            now: now
        )
        let meters = usage.groups.flatMap(\.meters)

        #expect(meters.map(\.id) == ["copilot-premium_interactions"])
        #expect(meters.map(\.percentRemaining) == [75])
    }

    @Test
    func requestIncludesCurrentClientHeaders() async throws {
        CopilotReliabilityHeaderRecorder.shared.reset()
        _ = try await CopilotReliabilityFixture.fetch(
            protocolClass: CopilotReliabilityHeaderURLProtocol.self,
            now: now
        )
        let headers = try #require(
            CopilotReliabilityHeaderRecorder.shared.recordedHeaders()
        )

        #expect(
            headers.url
                == "https://api.github.com/copilot_internal/user"
        )
        #expect(headers.method == "GET")
        #expect(headers.authorization == "token fixture-token")
        #expect(headers.accept == "application/json")
        #expect(headers.editorVersion == "vscode/1.96.2")
        #expect(headers.pluginVersion == "copilot-chat/0.26.7")
        #expect(headers.userAgent == "GitHubCopilotChat/0.26.7")
        #expect(headers.apiVersion == "2025-04-01")
    }
}

private enum CopilotReliabilityFixture {
    static func fetch(
        protocolClass: AnyClass,
        now: Date
    ) async throws -> ProviderUsage {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CopilotReliability-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let credentialURL = directory.appending(
            path: ".config/github-copilot/apps.json"
        )
        try FileManager.default.createDirectory(
            at: credentialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"github.com":{"oauth_token":"fixture-token"}}"#.utf8
        ).write(to: credentialURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let provider = CopilotUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: directory.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: CopilotReliabilityMissingKeychain(),
                homeDirectory: directory,
                commandPaths: []
            ),
            http: ProviderHTTP(session: session)
        )
        return try await provider.fetch(now: now)
    }

    static let validQuotaBody = Data(
        """
        {
          "copilot_plan": "individual",
          "quota_snapshots": {
            "premium_interactions": {"percent_remaining": 75}
          }
        }
        """.utf8
    )
}

private struct CopilotReliabilityMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private class CopilotReliabilityURLProtocol: URLProtocol,
    @unchecked Sendable
{
    class var body: Data { Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
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
        client?.urlProtocol(self, didLoad: type(of: self).body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CopilotReliabilityPlanOnlyURLProtocol:
    CopilotReliabilityURLProtocol,
    @unchecked Sendable
{
    override class var body: Data {
        Data(#"{"copilot_plan":"individual"}"#.utf8)
    }
}

private final class CopilotReliabilityFreeQuotaURLProtocol:
    CopilotReliabilityURLProtocol,
    @unchecked Sendable
{
    override class var body: Data {
        Data(
            """
            {
              "copilot_plan": "free",
              "limited_user_quotas": {
                "chat": 30,
                "completions": 1000
              },
              "monthly_quotas": {
                "chat": 50,
                "completions": 2000
              },
              "limited_user_reset_date": "2026-09-01T00:00:00Z"
            }
            """.utf8
        )
    }
}

private final class CopilotReliabilityUnlimitedURLProtocol:
    CopilotReliabilityURLProtocol,
    @unchecked Sendable
{
    override class var body: Data {
        Data(
            """
            {
              "copilot_plan": "individual",
              "quota_snapshots": {
                "premium_interactions": {
                  "percent_remaining": 75,
                  "unlimited": false
                },
                "chat": {
                  "percent_remaining": 100,
                  "unlimited": true
                },
                "completions": {
                  "percent_remaining": 100,
                  "unlimited": true
                }
              }
            }
            """.utf8
        )
    }
}

private final class CopilotReliabilityHeaderRecorder: @unchecked Sendable {
    static let shared = CopilotReliabilityHeaderRecorder()

    private let lock = NSLock()
    private var headers: (
        url: String?,
        method: String?,
        authorization: String?,
        accept: String?,
        editorVersion: String?,
        pluginVersion: String?,
        userAgent: String?,
        apiVersion: String?
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
                request.value(forHTTPHeaderField: "Editor-Version"),
                request.value(
                    forHTTPHeaderField: "Editor-Plugin-Version"
                ),
                request.value(forHTTPHeaderField: "User-Agent"),
                request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            )
        }
    }

    func recordedHeaders() -> (
        url: String?,
        method: String?,
        authorization: String?,
        accept: String?,
        editorVersion: String?,
        pluginVersion: String?,
        userAgent: String?,
        apiVersion: String?
    )? {
        lock.withLock { headers }
    }
}

private final class CopilotReliabilityHeaderURLProtocol:
    CopilotReliabilityURLProtocol,
    @unchecked Sendable
{
    override class var body: Data {
        CopilotReliabilityFixture.validQuotaBody
    }

    override func startLoading() {
        CopilotReliabilityHeaderRecorder.shared.record(request)
        super.startLoading()
    }
}
