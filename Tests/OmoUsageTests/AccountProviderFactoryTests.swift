import Foundation
import Testing
@testable import OmoUsage

@Suite
struct AccountProviderFactoryTests {
    @Test
    func registryCreatesReferencedAPIKeyAccountsAndOneCompanionRoster() {
        let openCode = AccountID()
        let firstRouter = AccountID()
        let secondRouter = AccountID()
        let zai = AccountID()
        let unreferenced = AccountID()
        let registry = ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: [
                ProviderAccount(id: .legacy, label: "Legacy Alias"),
                ProviderAccount(id: openCode, label: "OpenCode Account"),
                ProviderAccount(id: firstRouter, label: "First Router"),
                ProviderAccount(id: secondRouter, label: "Second Router"),
                ProviderAccount(id: zai, label: "Z.ai Account"),
                ProviderAccount(id: unreferenced, label: "Unreferenced")
            ],
            displayOrder: [],
            disconnected: [],
            apiKeyReferences: [
                AccountProviderID(accountID: zai, providerID: .zai),
                AccountProviderID(
                    accountID: secondRouter,
                    providerID: .openrouter
                ),
                AccountProviderID(accountID: openCode, providerID: .opencode),
                AccountProviderID(
                    accountID: firstRouter,
                    providerID: .openrouter
                )
            ]
        )

        let providers = ProviderFactory.current(
            registry: registry,
            environment: [:]
        )
        let companionIDs: [ProviderID] = [
            .claude, .codex, .cursor, .antigravity,
            .copilot, .devin, .grok
        ]
        let companions = providers.filter { companionIDs.contains($0.id) }

        for providerID in companionIDs {
            let matches = companions.filter { $0.id == providerID }
            #expect(matches.count == 1)
            #expect(matches.first?.accountID == .legacy)
            #expect(matches.first?.accountLabel == "Legacy Alias")
        }
        #expect(
            providers.filter { !companionIDs.contains($0.id) }
                .map(\.accountProviderID) == [
                    AccountProviderID(
                        accountID: openCode,
                        providerID: .opencode
                    ),
                    AccountProviderID(
                        accountID: firstRouter,
                        providerID: .openrouter
                    ),
                    AccountProviderID(
                        accountID: secondRouter,
                        providerID: .openrouter
                    ),
                    AccountProviderID(accountID: zai, providerID: .zai)
                ]
        )
        #expect(
            providers.filter { !companionIDs.contains($0.id) }
                .map(\.accountLabel) == [
                    "OpenCode Account",
                    "First Router",
                    "Second Router",
                    "Z.ai Account"
                ]
        )
        #expect(providers.allSatisfy { $0.accountID != unreferenced })
        #expect(providers.count == 11)
    }

    @Test
    func accountScopedOpenRouterProvidersUseTheirOwnCredentials() async throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "AccountProviderFactoryFetch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AccountID()
        let second = AccountID()
        try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: first,
            home: home,
            environment: [:]
        )).save("first-token")
        try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: second,
            home: home,
            environment: [:]
        )).save("second-token")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: AccountProviderMissingKeychain(),
            homeDirectory: home,
            commandPaths: []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountOpenRouterURLProtocol.self]
        let http = ProviderHTTP(session: URLSession(configuration: configuration))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let firstUsage = try await OpenRouterUsageProvider(
            discovery: discovery,
            http: http,
            accountID: first,
            accountLabel: "First"
        ).fetch(now: now)
        let secondUsage = try await OpenRouterUsageProvider(
            discovery: discovery,
            http: http,
            accountID: second,
            accountLabel: "Second"
        ).fetch(now: now)

        #expect(firstUsage.groups[0].meters[0].percentRemaining == 75)
        #expect(secondUsage.groups[0].meters[0].percentRemaining == 25)
    }
}

private struct AccountProviderMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private final class AccountOpenRouterURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
        let usage = token == "Bearer first-token" ? 25 : 75
        let body = request.url?.path.hasSuffix("/credits") == true
            ? #"{"data":{"total_credits":100,"total_usage":\#(usage)}}"#
            : #"{"data":{}}"#
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
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
