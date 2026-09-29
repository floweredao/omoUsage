import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite(.serialized)
struct ProviderContractTests {
    private let now = Date(timeIntervalSince1970: 1_788_220_800)

    @Test
    func catalogCoversEveryNetworkProviderWithUniqueTypedPurposes() {
        #expect(Set(ProviderContractCatalog.contracts.keys) == Set(ProviderID.allCases))

        for provider in ProviderID.allCases {
            let contract = ProviderContractCatalog.contract(for: provider)
            #expect(contract.provider == provider)
            #expect(contract.schemaRevision > 0)
            #expect(!contract.endpoints.isEmpty)
            #expect(Set(contract.endpoints.map(\.purpose)).count == contract.endpoints.count)
            #expect(contract.endpoints.allSatisfy { !$0.requiredHeaderNames.isEmpty })
        }
    }

    @Test
    func descriptorEnforcesPurposeMethodHeadersUserAgentAndRevision() throws {
        let endpoint = ProviderContractCatalog.endpoint(
            .codexUsage,
            for: .codex
        )
        var request = URLRequest(url: URL(string: "https://fixture.invalid/usage")!)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("fixture-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("fixture-agent", forHTTPHeaderField: "User-Agent")

        try endpoint.validate(request)

        #expect(endpoint.provider == .codex)
        #expect(endpoint.purpose == .codexUsage)
        #expect(endpoint.safety == .safe)
        #expect(endpoint.schemaRevision == ProviderContractCatalog.contract(for: .codex).schemaRevision)
        #expect(endpoint.userAgentPolicy == .requiredStable)

        request.httpMethod = "POST"
        #expect(throws: ProviderContractError.self) {
            try endpoint.validate(request)
        }
    }

    @Test
    func claudeTokenExchangeIsUnsafeJSONPostWithStableUserAgent() throws {
        let endpoint = ProviderContractCatalog.endpoint(.claudeTokenExchange, for: .claude)
        #expect(endpoint.method == .post)
        #expect(endpoint.safety == .unsafe)
        #expect(endpoint.userAgentPolicy == .requiredStable)
        #expect(endpoint.requiredHeaderNames == ["Content-Type", "Accept"])

        var request = try ClaudeBrowserAuthenticationClient.tokenRequest(
            code: "fixture-code", state: "fixture-state", verifier: "fixture-state",
            redirectURI: "http://localhost:53692/callback"
        )
        try endpoint.validate(request)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        request.setValue(nil, forHTTPHeaderField: "User-Agent")
        #expect(throws: ProviderContractError.self) {
            try endpoint.validate(request)
        }
    }

    @Test
    @MainActor
    func schemaMutationDisablesOnlyTargetAccountAndRecordsRevisionOnly() async throws {
        let target = AccountProviderID(
            accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000018")!,
            providerID: .openrouter
        )
        let sibling = AccountProviderID(
            accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000019")!,
            providerID: .openrouter
        )
        let revision = ProviderContractCatalog.contract(for: .openrouter).schemaRevision
        let diagnostics = DiagnosticStore(capacity: 4)
        let targetToken = "contract-mutated-fixture"
        let siblingToken = "contract-healthy-fixture"
        ContractFixtureRouter.configure(
            mutatedToken: targetToken,
            healthyToken: siblingToken
        )
        defer { ContractFixtureRouter.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let http = ProviderHTTP(session: session)
        let targetProvider = ContractRoutedProvider(
            identity: target,
            token: targetToken,
            http: http,
            now: now
        )
        let siblingProvider = ContractRoutedProvider(
            identity: sibling,
            token: siblingToken,
            http: http,
            now: now
        )
        var persistedDisabled: [Set<AccountProviderID>] = []
        let viewModel = UsageDashboardViewModel(
            providers: [targetProvider, siblingProvider],
            persistDisconnectedAccountProviders: {
                persistedDisabled.append($0)
            },
            diagnosticStore: diagnostics,
            now: { now }
        )

        await viewModel.refresh()

        #expect(viewModel.accountConnectionStates[target] == .schemaChanged)
        #expect(viewModel.accountConnectionStates[sibling] == .available)
        #expect(viewModel.schemaChangedAccountProviders == [target])
        #expect(viewModel.disconnectedAccountProviders.isEmpty)
        #expect(persistedDisabled.isEmpty)
        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == [sibling])
        #expect(await targetProvider.fetchCount == 1)
        #expect(await siblingProvider.fetchCount == 1)
        #expect(ContractFixtureRouter.requestCount == 2)
        #expect(
            ContractFixtureRouter.endpointPurposeIDs
                == ["openrouter.credits", "openrouter.credits"]
        )

        await viewModel.refresh()

        #expect(viewModel.accountConnectionStates[target] == .schemaChanged)
        #expect(viewModel.accountConnectionStates[sibling] == .available)
        #expect(viewModel.schemaChangedAccountProviders == [target])
        #expect(viewModel.disconnectedAccountProviders.isEmpty)
        #expect(persistedDisabled.isEmpty)
        #expect(await targetProvider.fetchCount == 1)
        #expect(await siblingProvider.fetchCount == 2)
        #expect(ContractFixtureRouter.requestCount == 3)

        ContractFixtureRouter.setMutationEnabled(false)
        viewModel.reconnectAccountProvider(target)
        #expect(viewModel.schemaChangedAccountProviders.isEmpty)
        #expect(persistedDisabled.isEmpty)
        await viewModel.refresh()
        #expect(viewModel.accountConnectionStates[target] == .available)
        #expect(await targetProvider.fetchCount == 2)
        #expect(await siblingProvider.fetchCount == 3)

        ContractFixtureRouter.setMutationEnabled(true)
        await viewModel.refresh()
        #expect(viewModel.accountConnectionStates[target] == .schemaChanged)
        #expect(viewModel.schemaChangedAccountProviders == [target])
        #expect(await targetProvider.fetchCount == 3)
        #expect(await siblingProvider.fetchCount == 4)

        ContractFixtureRouter.setMutationEnabled(false)
        await viewModel.retryAccountProvider(target)
        #expect(viewModel.accountConnectionStates[target] == .available)
        #expect(viewModel.schemaChangedAccountProviders.isEmpty)
        #expect(viewModel.disconnectedAccountProviders.isEmpty)
        #expect(persistedDisabled.isEmpty)
        #expect(await targetProvider.fetchCount == 4)
        #expect(await siblingProvider.fetchCount == 5)
        #expect(ContractFixtureRouter.requestCount == 9)

        let event = try #require(diagnostics.events.last)
        #expect(event.provider == .openrouter)
        #expect(event.status == .schemaChanged)
        #expect(event.category == .providerRefresh)
        #expect(event.contractRevision == revision)
        let exported = try #require(
            JSONSerialization.jsonObject(with: diagnostics.exportData())
                as? [[String: Any]]
        )
        let fields = try #require(exported.last)
        #expect(fields["provider"] as? String == ProviderID.openrouter.rawValue)
        #expect(fields["contractRevision"] as? Int == revision)
        #expect(!fields.keys.contains("endpoint"))
        #expect(!fields.keys.contains("url"))
        #expect(!fields.keys.contains("headers"))
        #expect(!fields.keys.contains("body"))
        #expect(!fields.keys.contains("error"))
    }

    @Test
    @MainActor
    func providerUpdatePrunesRuntimeSchemaDisable() async {
        let removed = AccountProviderID(
            accountID: AccountID(
                rawValue: "00000000-0000-0000-0000-000000000022"
            )!,
            providerID: .openrouter
        )
        let retained = AccountProviderID(
            accountID: AccountID(
                rawValue: "00000000-0000-0000-0000-000000000023"
            )!,
            providerID: .zai
        )
        let provider = ContractFixtureProvider(
            identity: removed,
            result: .failure(
                ProviderContractError.schemaChanged(
                    provider: .openrouter,
                    purpose: .openRouterCredits,
                    contractRevision: 1
                )
            )
        )
        let retainedProvider = ContractFixtureProvider(
            identity: retained,
            result: .failure(
                ProviderTransportError.transientTransport(
                    .zai,
                    .networkConnectionLost
                )
            )
        )
        let viewModel = UsageDashboardViewModel(
            providers: [provider, retainedProvider],
            diagnosticStore: DiagnosticStore(capacity: 2),
            now: { now }
        )

        await viewModel.refresh()
        #expect(viewModel.schemaChangedAccountProviders == [removed])

        viewModel.updateProviders(
            [retainedProvider],
            accountProviderOrder: [retained],
            disconnected: []
        )

        #expect(viewModel.schemaChangedAccountProviders.isEmpty)
        #expect(viewModel.accountConnectionStates[removed] == nil)
    }

    @Test
    @MainActor
    func authenticationAndTransientFailuresRemainDistinctAndEnabled() async {
        let authentication = AccountProviderID(
            accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000020")!,
            providerID: .openrouter
        )
        let transient = AccountProviderID(
            accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000021")!,
            providerID: .zai
        )
        let viewModel = UsageDashboardViewModel(
            providers: [
                ContractFixtureProvider(
                    identity: authentication,
                    result: .failure(
                        ProviderTransportError.authenticationRequired(.openrouter)
                    )
                ),
                ContractFixtureProvider(
                    identity: transient,
                    result: .failure(
                        ProviderTransportError.transientTransport(
                            .zai,
                            .networkConnectionLost
                        )
                    )
                )
            ],
            diagnosticStore: DiagnosticStore(capacity: 4),
            now: { now }
        )

        await viewModel.refresh()

        #expect(viewModel.accountConnectionStates[authentication] == .authenticationRequired)
        #expect(viewModel.accountConnectionStates[transient] == .failed)
        #expect(viewModel.disconnectedAccountProviders.isEmpty)
    }

}

private actor ContractFixtureProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let accountID: AccountID
    nonisolated let accountLabel = "Fixture Account"
    private let result: Result<ProviderUsage, any Error & Sendable>
    private(set) var fetchCount = 0

    init(
        identity: AccountProviderID,
        result: Result<ProviderUsage, any Error & Sendable>
    ) {
        id = identity.providerID
        accountID = identity.accountID
        self.result = result
    }

    func fetch(now: Date) throws -> ProviderUsage {
        fetchCount += 1
        return try result.get()
    }
}

private actor ContractRoutedProvider: UsageProvider {
    nonisolated let id = ProviderID.openrouter
    nonisolated let accountID: AccountID
    nonisolated let accountLabel = "Fixture Account"
    private let token: String
    private let http: ProviderHTTP
    private let now: Date
    private(set) var fetchCount = 0

    init(
        identity: AccountProviderID,
        token: String,
        http: ProviderHTTP,
        now: Date
    ) {
        accountID = identity.accountID
        self.token = token
        self.http = http
        self.now = now
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        fetchCount += 1
        let endpoint = ProviderContractCatalog.endpoint(
            .openRouterCredits,
            for: id
        )
        var request = URLRequest(
            url: URL(string: "https://contract-fixture.invalid/usage")!
        )
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            guard
                let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let remaining = object["remaining"] as? Int
            else {
                throw UsageParsingError.invalidPayload
            }
            return ProviderUsage(
                provider: id,
                accountID: accountID,
                accountLabel: accountLabel,
                planName: "Fixture",
                groups: [
                    UsageGroup(
                        id: "fixture-usage",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "fixture-week",
                                title: "Week",
                                period: .week,
                                percentRemaining: remaining
                            )
                        ],
                        creditText: nil
                    )
                ],
                availability: .available,
                updatedAt: self.now
            )
        }
    }
}

private enum ContractFixtureRouter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mutatedToken = ""
    nonisolated(unsafe) private static var healthyToken = ""
    nonisolated(unsafe) private static var mutationEnabled = false
    nonisolated(unsafe) private static var recordedPurposeIDs: [String] = []

    static var requestCount: Int {
        lock.withLock { recordedPurposeIDs.count }
    }

    static var endpointPurposeIDs: [String] {
        lock.withLock { recordedPurposeIDs }
    }

    static func configure(mutatedToken: String, healthyToken: String) {
        lock.withLock {
            self.mutatedToken = mutatedToken
            self.healthyToken = healthyToken
            mutationEnabled = true
            recordedPurposeIDs = []
        }
    }

    static func response(for request: URLRequest) -> String? {
        lock.withLock {
            recordedPurposeIDs.append(
                ProviderEndpointPurpose.openRouterCredits.rawValue
            )
            let authorization = request.value(
                forHTTPHeaderField: "Authorization"
            )
            if authorization == "Bearer \(mutatedToken)" {
                return mutationEnabled
                    ? #"{"shape":"mutated"}"#
                    : #"{"remaining":75}"#
            }
            if authorization == "Bearer \(healthyToken)" {
                return #"{"remaining":75}"#
            }
            return nil
        }
    }

    static func setMutationEnabled(_ enabled: Bool) {
        lock.withLock {
            mutationEnabled = enabled
        }
    }

    static func reset() {
        lock.withLock {
            mutatedToken = ""
            healthyToken = ""
            mutationEnabled = false
            recordedPurposeIDs = []
        }
    }
}

private final class ContractFixtureURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "contract-fixture.invalid"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let body = ContractFixtureRouter.response(for: request) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.userAuthenticationRequired)
            )
            return
        }
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
