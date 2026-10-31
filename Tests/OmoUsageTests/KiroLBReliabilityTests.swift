import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct KiroLBReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_793_414_498)
    private let reset = Date(timeIntervalSince1970: 1_793_491_200)

    @Test
    func loginPostsJSONPasswordAndAccountsCarryTheSessionCookie() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"]
        )
        defer { fixture.tearDown() }

        _ = try await fixture.fetch(now: now)

        let requests = fixture.requests
        #expect(requests.map(\.path) == ["/api/dashboard/login", "/api/dashboard/accounts"])
        let login = try #require(requests.first)
        #expect(login.method == "POST")
        #expect(login.headers["Content-Type"] == "application/json")
        let body = try #require(login.body)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object == ["password": "env-dashboard-password"])
        let accounts = try #require(requests.last)
        #expect(accounts.method == "GET")
        #expect(accounts.headers["Cookie"] == "kiro_lb_session=kirolb-test-session")
    }

    @Test
    func realSampleProducesPoolAndPerAccountMeters() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"]
        )
        defer { fixture.tearDown() }

        let usage = try await fixture.fetch(now: now)
        let meters = usage.groups.flatMap(\.meters)

        #expect(usage.provider == .kiroLB)
        #expect(usage.availability == .available)
        #expect(usage.planName == "Pro Max, Power")
        #expect(meters.map(\.id) == [
            "kirolb-pool", "kirolb-account-1", "kirolb-account-2", "kirolb-account-3"
        ])
        #expect(meters.map(\.title) == ["전체", "Pro Max 1", "Pro Max 2", "Power 3"])
        #expect(meters.map(\.percentRemaining) == [48, 0, 0, 95])
        #expect(meters.allSatisfy { $0.resetsAt == reset })
        #expect(!meters.contains { $0.title.contains("@") })
    }

    @Test
    func poolPercentWeighsEveryAccountByItsLimit() throws {
        let root = try ProviderPayload.object(Data(KiroLBFixture.sampleAccounts.utf8))
        let accounts = try #require(UsageJSON.array(root["accounts"]))
            .compactMap(KiroLBUsageParser.account)
        let pool = try #require(KiroLBUsageParser.poolRemainingPercent(accounts))

        #expect(abs(pool - 47.63845) < 0.000_001)
    }

    @Test
    func numericStringResetIsParsed() throws {
        let account = try #require(KiroLBUsageParser.account([
            "enabled": true,
            "usage": [
                "subscriptionTitle": "KIRO POWER",
                "currentUsage": 1,
                "usageLimit": 10,
                "nextDateReset": "1793491200.0"
            ]
        ]))

        #expect(account.resetsAt == reset)
    }

    @Test
    func disabledErroredNullAndLimitlessAccountsAreSkipped() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            accountsBody: KiroLBFixture.accountsWithSkippedEntries
        )
        defer { fixture.tearDown() }

        let meters = try await fixture.fetch(now: now).groups.flatMap(\.meters)

        #expect(meters.map(\.title) == ["전체", "Pro Max 1", "Power 2"])
        #expect(meters.map(\.percentRemaining) == [64, 0, 95])
    }

    @Test
    func noUsableAccountIsASchemaFailureNotZeroUsage() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            accountsBody: #"{"accounts":[{"id":"a","enabled":false,"usage":null}]}"#
        )
        defer { fixture.tearDown() }

        await #expect(throws: ProviderContractError.self) {
            try await fixture.fetch(now: now)
        }
    }

    @Test
    func loginRejectionRequiresAuthentication() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "wrong-password"],
            login: .init(status: 401, body: #"{"detail":"Invalid password"}"#)
        )
        defer { fixture.tearDown() }

        await #expect(throws: ProviderTransportError.authenticationRequired(.kiroLB)) {
            try await fixture.fetch(now: now)
        }
        #expect(fixture.requests.map(\.path) == ["/api/dashboard/login"])
    }

    @Test
    func accountsRejectionRequiresAuthentication() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            accountsStatus: 401
        )
        defer { fixture.tearDown() }

        await #expect(throws: ProviderTransportError.authenticationRequired(.kiroLB)) {
            try await fixture.fetch(now: now)
        }
    }

    @Test
    func unreachableGatewayIsATransportFailure() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            login: .init(failure: .cannotConnectToHost)
        )
        defer { fixture.tearDown() }

        await #expect(
            throws: ProviderTransportError.transientTransport(.kiroLB, .cannotConnectToHost)
        ) {
            try await fixture.fetch(now: now)
        }
    }

    @Test
    func plaintextNonLoopbackBaseIsRejectedBeforeAnyRequest() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            baseHost: "192.168.1.20"
        )
        defer { fixture.tearDown() }

        await #expect(throws: KiroLBGatewayError.insecureBaseURL) {
            try await fixture.fetch(now: now)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test
    func loopbackHostsAndHTTPSAreAccepted() throws {
        for value in [
            "http://127.0.0.1:8000", "http://localhost:8000",
            "http://[::1]:8000", "https://gateway.example.com"
        ] {
            #expect(throws: Never.self) {
                try KiroLBGatewayConfiguration.validatedBaseURL(value)
            }
        }
        #expect(throws: KiroLBGatewayError.invalidBaseURL) {
            try KiroLBGatewayConfiguration.validatedBaseURL("ftp://127.0.0.1")
        }
    }

    @Test
    func environmentFilePasswordAndPortAreDiscovered() async throws {
        let fixture = try KiroLBFixture(
            environment: [:],
            useEnvironmentFilePort: true,
            environmentFile: """
            # kiro-lb settings

            SERVER_HOST=0.0.0.0
            export DASHBOARD_PASSWORD="file-password # not a comment"   # trailing
            """
        )
        defer { fixture.tearDown() }

        _ = try await fixture.fetch(now: now)

        let body = try #require(fixture.requests.first?.body)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object == ["password": "file-password # not a comment"])
    }

    @Test
    func environmentFileParserHandlesQuotesAndComments() {
        let values = KiroLBGatewayConfiguration.parseEnvironmentFile("""
        # comment
        DASHBOARD_PASSWORD='single quoted'

        SERVER_PORT=8123 # inline
        EMPTY=
        """)

        #expect(values == [
            "DASHBOARD_PASSWORD": "single quoted",
            "SERVER_PORT": "8123"
        ])
    }

    @Test
    func environmentPasswordTakesPrecedenceOverEnvironmentFile() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            environmentFile: "DASHBOARD_PASSWORD=file-password\n"
        )
        defer { fixture.tearDown() }

        _ = try await fixture.fetch(now: now)

        let body = try #require(fixture.requests.first?.body)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object == ["password": "env-dashboard-password"])
    }

    @Test
    func missingPasswordIsNotFoundWithoutAnyRequest() async throws {
        let fixture = try KiroLBFixture(environment: [:])
        defer { fixture.tearDown() }

        await #expect(throws: CredentialDiscoveryError.notFound(.kiroLB)) {
            try await fixture.fetch(now: now)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test
    func disabledDashboardAuthReadsAccountsWithoutCookie() async throws {
        let fixture = try KiroLBFixture(
            environment: ["KIRO_LB_DASHBOARD_PASSWORD": "env-dashboard-password"],
            login: .init(status: 200, body: #"{"ok":true,"authRequired":false}"#)
        )
        defer { fixture.tearDown() }

        let usage = try await fixture.fetch(now: now)

        #expect(usage.groups.flatMap(\.meters).count == 4)
        #expect(fixture.requests.last?.headers["Cookie"] == nil)
    }

    @Test
    func subscriptionTitlesDropTheKiroPrefix() {
        #expect(KiroLBUsageParser.displayTitle("KIRO PRO MAX") == "Pro Max")
        #expect(KiroLBUsageParser.displayTitle("KIRO POWER") == "Power")
        #expect(KiroLBUsageParser.displayTitle(nil) == "Kiro")
    }
}

@Suite
struct KiroLBGatingTests {
    @Test
    @MainActor
    func experimentalFlagDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "KiroLBGating-\(UUID().uuidString)"))
        let store = ExperimentalFeatureStore(defaults: defaults)

        #expect(store.isKiroLBEnabled == false)
        store.setKiroLBEnabled(true)

        #expect(store.isKiroLBEnabled)
        #expect(ExperimentalFeatureStore.isKiroLBEnabled(in: defaults))
        #expect(defaults.bool(forKey: ExperimentalFeatureStore.kiroLBDefaultsKey))
    }

    @Test(arguments: [false, true])
    func factoryBuildsKiroLBOnlyWhenEnabled(enabled: Bool) throws {
        let defaults = try #require(UserDefaults(suiteName: "KiroLBGating-\(UUID().uuidString)"))
        defaults.set(enabled, forKey: ExperimentalFeatureStore.kiroLBDefaultsKey)
        let other = AccountID()
        let registry = ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: [
                ProviderAccount(id: .legacy, label: AccountLabel.defaultValue),
                ProviderAccount(id: other, label: "Second")
            ],
            displayOrder: [],
            disconnected: [],
            providerReferences: [
                AccountProviderID(accountID: .legacy, providerID: .openrouter),
                AccountProviderID(accountID: other, providerID: .kiroLB)
            ]
        )

        let identities = ProviderFactory.current(
            registry: registry,
            environment: [:],
            defaults: defaults,
            discovery: KiroLBFixture.emptyDiscovery,
            http: ProviderHTTP(session: URLSession(configuration: .ephemeral))
        ).map(\.accountProviderID)

        let kiroLB = identities.filter { $0.providerID == .kiroLB }
        #expect(identities.contains(
            AccountProviderID(accountID: .legacy, providerID: .openrouter)
        ))
        #expect(kiroLB == (enabled ? [
            AccountProviderID(accountID: .legacy, providerID: .kiroLB),
            AccountProviderID(accountID: other, providerID: .kiroLB)
        ] : []))
    }

    @Test
    @MainActor
    func providerOrderOmitsExcludedProvidersUntilEnabled() {
        let viewModel = UsageDashboardViewModel(
            providers: [
                FixtureUsageProvider(id: .openrouter),
                FixtureUsageProvider(id: .kiroLB)
            ],
            excludedProviders: [.kiroLB],
            diagnosticStore: DiagnosticStore(),
            now: { Date(timeIntervalSince1970: 1_793_414_498) }
        )

        #expect(!viewModel.providerOrder.contains(.kiroLB))
        #expect(viewModel.providerOrder.contains(.openrouter))

        viewModel.updateProviders(
            [FixtureUsageProvider(id: .openrouter), FixtureUsageProvider(id: .kiroLB)],
            accountProviderOrder: viewModel.accountProviderOrder,
            disconnected: [],
            excludedProviders: []
        )

        #expect(viewModel.providerOrder.contains(.kiroLB))
        #expect(viewModel.providerOrder.count == ProviderID.allCases.count)
    }

    @Test
    func iCloudPayloadNeverCarriesKiroLBUsage() throws {
        let older = Date(timeIntervalSince1970: 1_793_400_000)
        let newer = Date(timeIntervalSince1970: 1_793_414_000)
        let snapshot = DashboardSnapshot(
            providers: [
                Self.usage(.openrouter, successAt: newer),
                Self.usage(.kiroLB, successAt: older)
            ],
            generatedAt: newer,
            lastRefreshAttemptAt: newer,
            oldestDisplayedSuccessAt: older
        )

        let cloud = try UsageSnapshotCodec.encode(snapshot)
        let decoded = try UsageSnapshotCodec.decode(cloud)
        let local = try UsageSnapshotCodec.encodeForLocalDashboard(snapshot)

        #expect(decoded.providers.map(\.provider) == [.openrouter])
        #expect(decoded.oldestDisplayedSuccessAt == newer)
        #expect(String(decoding: cloud, as: UTF8.self).contains("kiroLB") == false)
        #expect(String(decoding: local, as: UTF8.self).contains("kiroLB"))
    }

    private static func usage(_ provider: ProviderID, successAt: Date) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: "Plan",
            groups: [
                UsageGroup(
                    id: "\(provider.rawValue)-usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "\(provider.rawValue)-meter",
                            title: "주간",
                            period: .week,
                            percentRemaining: 50
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: successAt,
            refreshFailure: nil
        )
    }
}

private struct KiroLBFixture {
    struct Login: Sendable {
        var status = 200
        var body = #"{"ok":true}"#
        var setCookie: String? = "kiro_lb_session=kirolb-test-session; HttpOnly; Max-Age=604800; Path=/; SameSite=strict"
        var failure: URLError.Code?

        init(status: Int = 200, body: String = #"{"ok":true}"#) {
            self.status = status
            self.body = body
            if status != 200 || body.contains("authRequired") { setCookie = nil }
        }

        init(failure: URLError.Code) {
            self.failure = failure
            setCookie = nil
        }
    }

    static let sampleAccounts = #"""
    {"accounts":[
    {"id":"acct-1","enabled":true,"routingState":"quota_exhausted","quotaHeadroom":0,"quotaResetsAt":1793491200,
     "usage":{"email":"first@example.com","subscriptionTitle":"KIRO PRO MAX","resourceType":"CREDIT","currentUsage":5000,"usageLimit":5000,"nextDateReset":1793491200,"error":null}},
    {"id":"acct-2","enabled":true,"routingState":"quota_exhausted","quotaResetsAt":1793491200,
     "usage":{"email":"second@example.com","subscriptionTitle":"KIRO PRO MAX","currentUsage":5000,"usageLimit":5000,"nextDateReset":"1793491200.0","error":null}},
    {"id":"acct-3","enabled":true,"routingState":"available","quotaHeadroom":0.95,"quotaResetsAt":1793491200,
     "usage":{"email":"third@example.com","subscriptionTitle":"KIRO POWER","currentUsage":472.31,"usageLimit":10000,"nextDateReset":"1793491200.0","daysUntilReset":null,"error":null}}
    ]}
    """#

    static let accountsWithSkippedEntries = #"""
    {"accounts":[
    {"id":"acct-1","enabled":true,"usage":{"subscriptionTitle":"KIRO PRO MAX","currentUsage":5000,"usageLimit":5000,"nextDateReset":1793491200,"error":null}},
    {"id":"acct-off","enabled":false,"usage":{"subscriptionTitle":"KIRO POWER","currentUsage":1,"usageLimit":10000,"nextDateReset":1793491200}},
    {"id":"acct-null","enabled":true,"usage":null},
    {"id":"acct-error","enabled":true,"usage":{"subscriptionTitle":"KIRO POWER","currentUsage":1,"usageLimit":10000,"error":"token expired"}},
    {"id":"acct-zero","enabled":true,"usage":{"subscriptionTitle":"KIRO FREE","currentUsage":0,"usageLimit":0}},
    {"id":"acct-3","enabled":true,"usage":{"subscriptionTitle":"KIRO POWER","currentUsage":472.31,"usageLimit":10000,"nextDateReset":"1793491200.0","error":null}}
    ]}
    """#

    static var emptyDiscovery: CredentialDiscovery {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "KiroLBEmpty-\(UUID().uuidString)", directoryHint: .isDirectory)
        return CredentialDiscovery(
            paths: CredentialPaths(
                claude: directory.appending(path: "missing-claude.json"),
                codex: directory.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: KiroLBMissingKeychain(),
            homeDirectory: directory,
            commandPaths: []
        )
    }

    let home: URL
    let port: Int
    let provider: KiroLBUsageProvider
    let session: URLSession

    init(
        environment: [String: String],
        login: Login = Login(),
        accountsStatus: Int = 200,
        accountsBody: String = Self.sampleAccounts,
        baseHost: String = "127.0.0.1",
        useEnvironmentFilePort: Bool = false,
        environmentFile: String? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory.appending(
            path: "KiroLBReliability-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        port = KiroLBURLProtocol.nextPort()
        var environment = environment
        var fileText = environmentFile
        if useEnvironmentFilePort {
            fileText = (fileText ?? "") + "\nSERVER_PORT=\(port)\n"
        } else {
            environment["KIRO_LB_URL"] = "http://\(baseHost):\(port)"
        }
        if let fileText {
            let file = KiroLBGatewayConfiguration.environmentFileComponents
                .reduce(home) { $0.appending(path: $1) }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(fileText.utf8).write(to: file)
        }
        KiroLBURLProtocol.register(
            port: port,
            scenario: KiroLBScenario(
                login: login,
                accountsStatus: accountsStatus,
                accountsBody: accountsBody
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroLBURLProtocol.self]
        session = URLSession(configuration: configuration)
        provider = KiroLBUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: home.appending(path: "missing-claude.json"),
                    codex: home.appending(path: "missing-codex.json")
                ),
                environment: environment,
                keychain: KiroLBMissingKeychain(),
                homeDirectory: home,
                commandPaths: []
            ),
            http: providerHTTPTestClient(session: session)
        )
    }

    var requests: [KiroLBRecordedRequest] {
        KiroLBURLProtocol.requests(port: port)
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        try await provider.fetch(now: now)
    }

    func tearDown() {
        session.finishTasksAndInvalidate()
        KiroLBURLProtocol.unregister(port: port)
        try? FileManager.default.removeItem(at: home)
    }
}

private struct KiroLBMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private struct KiroLBScenario: Sendable {
    let login: KiroLBFixture.Login
    let accountsStatus: Int
    let accountsBody: String
}

private struct KiroLBRecordedRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

private final class KiroLBURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var port = 41_000
    nonisolated(unsafe) private static var scenarios: [Int: KiroLBScenario] = [:]
    nonisolated(unsafe) private static var recorded: [Int: [KiroLBRecordedRequest]] = [:]

    static func nextPort() -> Int {
        lock.withLock {
            port += 1
            return port
        }
    }

    static func register(port: Int, scenario: KiroLBScenario) {
        lock.withLock { scenarios[port] = scenario }
    }

    static func unregister(port: Int) {
        lock.withLock {
            scenarios[port] = nil
            recorded[port] = nil
        }
    }

    static func requests(port: Int) -> [KiroLBRecordedRequest] {
        lock.withLock { recorded[port] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let port = url.port,
            let scenario = Self.lock.withLock({ Self.scenarios[port] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lock.withLock {
            Self.recorded[port, default: []].append(
                KiroLBRecordedRequest(
                    method: request.httpMethod ?? "GET",
                    path: url.path,
                    headers: request.allHTTPHeaderFields ?? [:],
                    body: requestBodyData(request)
                )
            )
        }
        var headers = ["Content-Type": "application/json"]
        let status: Int
        let body: String
        switch url.path {
        case "/api/dashboard/login":
            if let failure = scenario.login.failure {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            status = scenario.login.status
            body = scenario.login.body
            headers["Set-Cookie"] = scenario.login.setCookie
        case "/api/dashboard/accounts":
            let expectsCookie = scenario.login.setCookie != nil
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            let authorized = expectsCookie
                ? cookie == "kiro_lb_session=kirolb-test-session"
                : cookie == nil
            status = authorized ? scenario.accountsStatus : 401
            body = status == 200 ? scenario.accountsBody : #"{"detail":"Unauthorized"}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
