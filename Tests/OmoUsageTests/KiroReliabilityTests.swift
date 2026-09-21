import Foundation
import Testing
import Synchronization
@testable import OmoUsage
@testable import OmoUsageCore

@Suite(.serialized)
struct KiroUsageProviderTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    @Test
    func registersSafeGetUsageLimitsQueryContract() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let contract = try #require(ProviderContractCatalog.contracts[kiro])
        let endpoint = try #require(contract.endpoints.first)
        #expect(contract.endpoints.count == 1)
        #expect(endpoint.method == .post)
        #expect(endpoint.safety == .safe)
        #expect(endpoint.requiredHeaderNames == [
            "Authorization", "Content-Type", "X-Amz-Target"
        ])
    }

    @Test(arguments: ["us-east-1", "eu-central-1"])
    func exactRequestUsesPinnedAccountAndExcludesOverage(_ region: String) async throws {
        let usage = try await fetch(payload: payload(used: "125.5", limit: "200.5", overage: "25.25"), region: region)
        let request = try #require(KiroTestProtocol.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == (region == "us-east-1"
            ? "https://codewhisperer.us-east-1.amazonaws.com/"
            : "https://q.eu-central-1.amazonaws.com/"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval > 0 && request.timeoutInterval <= 10)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer snapshot-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "AmazonCodeWhispererService.GetUsageLimits")
        let body = try #require(KiroTestProtocol.state.withLock { $0.bodies.first })
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["profileArn": "arn:aws:codewhisperer:\(region):123456789012:profile/test"])
        #expect(usage.planName == "KIRO PRO")
        #expect(usage.accountID.rawValue == "00000000-0000-0000-0000-000000000002")
        #expect(usage.accountLabel == "Isolated")
        let meter = try #require(usage.groups.first?.meters.first)
        #expect(meter.percentRemaining == 50)
        #expect(meter.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.updatedAt == now)
    }

    @Test(arguments: [
        "\"bonuses\":[{\"usageLimit\":50}]",
        "\"freeTrialInfo\":{\"freeTrialStatus\":\"ACTIVE\",\"usageLimit\":500}"
    ])
    func ambiguousAttributionIsInformational(_ extra: String) async throws {
        let usage = try await fetch(payload: payload(used: "250", limit: "200", extra: extra))
        let meters = usage.groups.flatMap(\.meters)
        #expect(meters.count == 1)
        #expect(meters.first?.metric.kind == .informational)
        #expect(meters.first?.percentRemaining == nil)
        #expect(meters.first?.showsMenuBarBadge == false)
    }

    @Test(arguments: [
        ("-1", "100", "0"),
        ("25", "-1", "0"),
        ("25", "100", "-1"),
        ("25", "100", "30"),
        ("101", "100", "0"),
        ("true", "100", "0"),
        ("25", "false", "0"),
        ("25", "100", "true"),
        ("\"NaN\"", "100", "0")
    ])
    func rejectsInvalidCreditNumbers(_ values: (String, String, String)) async {
        await expectSchemaFailure(payload(used: values.0, limit: values.1, overage: values.2))
    }

    @Test
    func overflowingJSONNumberFailsAtTheTransportBoundary() async {
        do {
            _ = try await fetch(payload: payload(used: "1e999"))
            Issue.record("Overflowing JSON must not produce usage")
        } catch {
            #expect(error as? ProviderTransportError == .invalidJSON(.kiro))
        }
    }

    @Test(arguments: [
        #"{"usageBreakdownList":[],"nextDateReset":1800000000}"#,
        #"{"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100}],"nextDateReset":1800000000}"#,
        #"{"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":10}],"nextDateReset":1800000000000}"#,
        #"{"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":10}]}"#
    ])
    func rejectsMissingMetersAndInvalidReset(_ json: String) async {
        await expectSchemaFailure(json)
    }

    @Test
    func rejectsDuplicateCredits() async {
        let meter = #"{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":10}"#
        await expectSchemaFailure(#"{"usageBreakdownList":["# + meter + "," + meter + #"],"nextDateReset":1800000000}"#)
    }

    @Test(arguments: [401, 403, 500])
    func preservesTypedHTTPFailures(_ status: Int) async {
        do {
            _ = try await fetch(payload: "{}", status: status)
            Issue.record("HTTP failure must not report a valid balance")
        } catch {
            #expect(error as? ProviderTransportError == (status == 500
                ? .requestFailed(.kiro, status) : .authenticationRequired(.kiro)))
        }
    }

    @Test
    func retriesSafeQueryWithoutSleeping() async throws {
        _ = try await fetch(payload: payload(), statuses: [500, 200], attempts: 2)
        #expect(KiroTestProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test
    func expiredSnapshotNeverSendsARequest() async {
        do {
            _ = try await fetch(payload: payload(), expiry: now)
            Issue.record("Expired account must require reimport")
        } catch {
            #expect(error as? CredentialDiscoveryError == .expired(.kiro))
        }
        #expect(KiroTestProtocol.state.withLock { $0.requests.isEmpty })
    }

    private func expectSchemaFailure(_ json: String) async {
        do {
            _ = try await fetch(payload: json)
            Issue.record("Invalid usage must not become an authoritative quota")
        } catch {
            #expect(error as? ProviderContractError == .schemaChanged(
                provider: .kiro, purpose: .kiroUsageLimits, contractRevision: 1
            ))
        }
    }

    private func payload(
        used: String = "25", limit: String = "100", overage: String = "0",
        extra: String? = nil
    ) -> String {
        """
        {"usageBreakdownList":[{"resourceType":"CREDIT",
        "currentUsageWithPrecision":\(used),"usageLimitWithPrecision":\(limit),
        "currentOveragesWithPrecision":\(overage)\(extra.map { "," + $0 } ?? "")}],
        "nextDateReset":1800000000,"subscriptionInfo":{"subscriptionTitle":"KIRO PRO"}}
        """
    }

    private func fetch(
        payload: String, region: String = "us-east-1", status: Int = 200,
        statuses: [Int]? = nil, attempts: Int = 1, expiry: Date? = nil
    ) async throws -> ProviderUsage {
        KiroTestProtocol.state.withLock {
            $0 = KiroTestProtocol.State(data: Data(payload.utf8), statuses: statuses ?? [status])
        }
        let account = try #require(AccountID(rawValue: "00000000-0000-0000-0000-000000000002"))
        let snapshot = CredentialSnapshot(
            provider: .kiro, accessToken: "snapshot-token", refreshToken: nil,
            accountReference: "arn:aws:codewhisperer:\(region):123456789012:profile/test",
            planName: nil, expiresAt: expiry ?? now.addingTimeInterval(600), source: .file
        )
        let key = ProviderCredentialSnapshotStore.account(
            for: AccountProviderID(accountID: account, providerID: .kiro)
        )
        let reader = KiroProviderKeychain(key: key, secret: try snapshot.encodedSecret())
        let home = URL(fileURLWithPath: "/isolated/kiro-provider-tests")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: home, codex: home),
            environment: [:], keychain: reader,
            homeDirectory: home, commandPaths: []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = providerHTTPTestClient(
            session: session, retryPolicy: ProviderRetryPolicy(maximumAttempts: attempts)
        )
        return try await KiroUsageProvider(
            discovery: discovery, http: http, accountID: account, accountLabel: "Isolated"
        ).fetch(now: now)
    }
}

private struct KiroProviderKeychain: KeychainReading {
    let key: String
    let secret: String
    func value(service: String, account: String) throws -> String? {
        account == key ? secret : nil
    }
}

private final class KiroTestProtocol: URLProtocol {
    struct State {
        var data = Data()
        var statuses: [Int] = [200]
        var requests: [URLRequest] = []
        var bodies: [Data] = []
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = requestBodyData(request)
        let (data, status) = Self.state.withLock { state in
            let status = state.statuses[min(state.requests.count, state.statuses.count - 1)]
            state.requests.append(request)
            if let body { state.bodies.append(body) }
            return (state.data, status)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/x-amz-json-1.0"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
