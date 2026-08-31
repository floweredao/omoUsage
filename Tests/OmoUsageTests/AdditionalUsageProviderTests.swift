import Foundation
import Testing
@testable import OmoUsage

@Suite
struct AdditionalUsageProviderTests {
    @Test
    func parsesEveryNetworkProviderSurface() async throws {
        try await withFixtureDirectory { home in
            try writeCredentials(home)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: "claude.json"),
                    codex: home.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: UsageKeychain(),
                homeDirectory: home
            )
            let http = ProviderHTTP(session: fixtureSession())
            let providers: [any UsageProvider] = [
                CopilotUsageProvider(discovery: discovery, http: http),
                CursorUsageProvider(discovery: discovery, http: http),
                DevinUsageProvider(discovery: discovery, http: http),
                GrokUsageProvider(discovery: discovery, http: http),
                OpenRouterUsageProvider(discovery: discovery, http: http),
                ZAIUsageProvider(discovery: discovery, http: http)
            ]

            var usages: [ProviderUsage] = []
            for provider in providers {
                usages.append(try await provider.fetch(now: .now))
            }

            #expect(usages.map(\.provider) == [
                .copilot, .cursor, .devin, .grok, .openrouter, .zai
            ])
            #expect(usages.allSatisfy { !$0.groups.isEmpty })
            #expect(usages.allSatisfy {
                $0.groups.contains { !$0.meters.isEmpty }
            })
            #expect(
                usages.first { $0.provider == .cursor }?
                    .groups[0].meters[0].percentRemaining == 60
            )
            #expect(
                usages.first { $0.provider == .copilot }?
                    .groups[0].meters[0].percentRemaining == 88
            )
        }
    }

    @Test
    func scansOpenCodeLocalUsageDatabase() async throws {
        try await withFixtureDirectory { home in
            let directory = home.appending(
                path: ".local/share/opencode"
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let database = directory.appending(path: "opencode.db")
            try createOpenCodeDatabase(database)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: "claude.json"),
                    codex: home.appending(path: "codex.json")
                ),
                environment: [:],
                keychain: UsageKeychain(),
                homeDirectory: home
            )

            let usage = try await OpenCodeUsageProvider(
                discovery: discovery
            ).fetch(now: .now)

            #expect(usage.provider == .opencode)
            #expect(usage.planName == "Zen")
            #expect(usage.groups[0].meters.map(\.metric) == [
                .spend(amount: 3, currency: .usd)
            ])
            #expect(usage.groups[0].creditText == nil)
        }
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func writeCredentials(_ home: URL) throws {
        try createCursorDatabase(home)
        try writeJSON(
            ["github.com": ["oauth_token": "copilot-token"]],
            to: home.appending(
                path: ".config/github-copilot/apps.json"
            )
        )
        try writeText(
            "windsurf_api_key = \"devin-token\"",
            to: home.appending(
                path: ".local/share/devin/credentials.toml"
            )
        )
        try writeJSON(
            ["account": ["key": "grok-token"]],
            to: home.appending(path: ".grok/auth.json")
        )
        try writeJSON(
            ["apiKey": "openrouter-token"],
            to: home.appending(
                path: ".config/openusage/openrouter.json"
            )
        )
        try writeJSON(
            ["apiKey": "zai-token"],
            to: home.appending(
                path: ".config/openusage/zai.json"
            )
        )
    }

    private func createCursorDatabase(_ home: URL) throws {
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            """
            CREATE TABLE ItemTable(key TEXT, value TEXT);
            INSERT INTO ItemTable VALUES(
              'cursorAuth/accessToken',
              'cursor-token'
            );
            """
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func createOpenCodeDatabase(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        let now = Int(Date.now.timeIntervalSince1970 * 1_000)
        let payload = #"{"role":"assistant","providerID":"opencode-go","cost":3}"#
        process.arguments = [
            url.path,
            """
            CREATE TABLE message(time_created INTEGER, data TEXT);
            INSERT INTO message VALUES(\(now), '\(payload)');
            """
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func writeJSON(
        _ object: [String: Any],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func withFixtureDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private struct UsageKeychain: KeychainReading {
    var values: [String: String] = [:]

    func value(service: String, account: String) throws -> String? {
        values[service]
    }
}

private final class ProviderFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.body(for: url)
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

    private static func body(for url: URL) -> String {
        let path = url.path
        if path.contains("copilot_internal") {
            return #"{"copilot_plan":"pro","quota_snapshots":{"premium_interactions":{"percent_remaining":88},"chat":{"percent_remaining":100}}}"#
        }
        if path.contains("/api/usage-summary") {
            return #"{"planUsage":{"usedPercent":40},"autoUsage":{"usedPercent":10},"apiUsage":{"usedPercent":20},"creditBalance":12}"#
        }
        if path.contains("/auth/me") {
            return #"{"planName":"Pro"}"#
        }
        if path.contains("GetUserStatus") {
            return #"{"planName":"Core","weeklyQuota":{"usedPercent":32},"dailyQuota":{"usedPercent":20},"extraBalance":10}"#
        }
        if path.contains("/v1/billing") {
            return #"{"weekly":{"used_percent":25},"pay_as_you_go":{"monthly_cap":2500}}"#
        }
        if path.contains("/v1/settings") {
            return #"{"planName":"SuperGrok"}"#
        }
        if path.contains("/credits") {
            return #"{"data":{"total_credits":100,"total_usage":25}}"#
        }
        if path.contains("/api/v1/key") {
            return #"{"data":{"label":"main","usage":10,"limit":20,"usage_daily":1}}"#
        }
        if path.contains("/quota/limit") {
            return #"{"data":{"limits":[{"type":"TOKENS_LIMIT","used":40,"limit":100},{"type":"TOKENS_LIMIT","used":20,"limit":100,"nextResetTime":1910000000000},{"type":"TIME_LIMIT","used":2,"limit":10}]}}"#
        }
        if path.contains("/subscription/list") {
            return #"{"data":{"planName":"Pro"}}"#
        }
        return #"{}"#
    }
}
