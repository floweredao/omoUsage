import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct AccountProviderFactoryTests {
    @Test
    func registryCreatesReferencedAccountsForEveryProvider() {
        let accountIDs = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map {
                ($0, AccountID())
            }
        )
        let references = ProviderID.allCases.map {
            AccountProviderID(
                accountID: accountIDs[$0]!,
                providerID: $0
            )
        }
        let registry = ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: [ProviderAccount(id: .legacy, label: "Legacy Alias")]
                + ProviderID.allCases.map {
                    ProviderAccount(
                        id: accountIDs[$0]!,
                        label: "\($0.displayName) Account"
                    )
                },
            displayOrder: [],
            disconnected: [],
            providerReferences: references
        )

        let providers = ProviderFactory.current(
            registry: registry,
            environment: ["OMO_USAGE_FIXTURE_MODE": "1"]
        )

        #expect(providers.map(\.accountProviderID) == references)
        #expect(
            providers.map(\.accountLabel)
                == ProviderID.allCases.map { "\($0.displayName) Account" }
        )
        #expect(providers.count == ProviderID.allCases.count)
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
        let providerKeychain = AccountProviderFakeKeychain()
        try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: first,
            home: home,
            environment: [:],
            keychain: providerKeychain
        )).save("first-token")
        try #require(ProviderAPIKeyStore.live(
            for: .openrouter,
            accountID: second,
            home: home,
            environment: [:],
            keychain: providerKeychain
        )).save("second-token")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: AccountProviderMissingKeychain(),
            providerKeychain: providerKeychain,
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

        #expect(firstUsage.groups[0].meters.first {
            $0.id == "openrouter-credit-balance"
        }?.metric == .credit(balance: 75, unit: .usd))
        #expect(secondUsage.groups[0].meters.first {
            $0.id == "openrouter-credit-balance"
        }?.metric == .credit(balance: 25, unit: .usd))
    }
}

private final class AccountProviderFakeKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "|" + account] }
    }
    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "|" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "|" + account) }
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
