import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite(.serialized)
struct ClaudePlanProfileTests {
    private let now = Date(timeIntervalSince1970: 1_791_180_000)

    @Test
    func browserGrantShowsProfilePlanAndReadsProfileOncePerAccount() async throws {
        let fixture = try PlanProfileFixture(planName: nil, now: now)
        PlanProfileURLProtocol.install(profile: .ok(Self.maxProfile))
        defer { PlanProfileURLProtocol.uninstall() }
        let provider = fixture.provider(planCache: ClaudePlanCache())

        let first = try await provider.fetch(now: now)
        let second = try await provider.fetch(now: now.addingTimeInterval(60))

        #expect(first.availability == .available)
        #expect(first.planName == "Max 20x")
        #expect(second.planName == "Max 20x")
        #expect(PlanProfileURLProtocol.count(.usage) == 2)
        #expect(PlanProfileURLProtocol.count(.profile) == 1)
        let request = try #require(PlanProfileURLProtocol.lastProfileRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(PlanProfileFixture.accessToken)")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudeUsageProvider.cliUserAgent)
    }

    @Test(arguments: [
        PlanProfileResponse.status(429),
        PlanProfileResponse.status(500),
        PlanProfileResponse.ok(#"{"account":{"has_claude_max":true}}"#)
    ])
    func profileFailureKeepsUsageAndWaitsBeforeRetrying(
        _ response: PlanProfileResponse
    ) async throws {
        let fixture = try PlanProfileFixture(planName: nil, now: now)
        PlanProfileURLProtocol.install(profile: response)
        defer { PlanProfileURLProtocol.uninstall() }
        let provider = fixture.provider(
            planCache: ClaudePlanCache(retryInterval: 1_800)
        )

        let first = try await provider.fetch(now: now)
        let lookups = PlanProfileURLProtocol.count(.profile)
        let throttled = try await provider.fetch(now: now.addingTimeInterval(60))
        let throttledLookups = PlanProfileURLProtocol.count(.profile)
        _ = try await provider.fetch(now: now.addingTimeInterval(1_801))

        #expect(first.availability == .available)
        #expect(first.planName.isEmpty)
        #expect(throttled.availability == .available)
        #expect(lookups > 0)
        #expect(throttledLookups == lookups)
        #expect(PlanProfileURLProtocol.count(.profile) > lookups)
        #expect(PlanProfileURLProtocol.count(.usage) == 3)
    }

    @Test
    func credentialPlanIsUsedWithoutAProfileRequest() async throws {
        let fixture = try PlanProfileFixture(planName: "Max 5x", now: now)
        PlanProfileURLProtocol.install(profile: .ok(Self.maxProfile))
        defer { PlanProfileURLProtocol.uninstall() }

        let usage = try await fixture.provider(planCache: ClaudePlanCache())
            .fetch(now: now)

        #expect(usage.planName == "Max 5x")
        #expect(PlanProfileURLProtocol.count(.profile) == 0)
    }

    @Test(arguments: [
        (#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#, "Max 20x"),
        (#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#, "Max 5x"),
        (#"{"organization":{"organization_type":"claude_pro","rate_limit_tier":"default_claude_ai"}}"#, "Pro"),
        (#"{"organization":{"organization_type":"claude_team"}}"#, "Team")
    ])
    func profileOrganizationMapsToPlanName(
        _ body: String,
        _ expected: String
    ) {
        #expect(ClaudePlanName.fromProfile(Data(body.utf8)) == expected)
    }

    @Test(arguments: [
        #"{"organization":{"organization_type":"api"}}"#,
        #"{"organization":{"organization_type":"claude_"}}"#,
        #"{"account":{"has_claude_max":true}}"#,
        "not json"
    ])
    func profileWithoutAClaudeSubscriptionHasNoPlan(_ body: String) {
        #expect(ClaudePlanName.fromProfile(Data(body.utf8)) == nil)
    }

    private static let maxProfile = """
        {
          "account": {"has_claude_max": true, "has_claude_pro": false},
          "organization": {
            "organization_type": "claude_max",
            "rate_limit_tier": "default_claude_max_20x"
          }
        }
        """
}

enum PlanProfileResponse: Sendable, CustomTestStringConvertible {
    case ok(String)
    case status(Int)

    var testDescription: String {
        switch self {
        case .ok: "malformed 200"
        case .status(let code): "HTTP \(code)"
        }
    }
}

private struct PlanProfileFixture {
    static let accessToken = "plan-profile-access"

    let accountID = AccountID()
    let discovery: CredentialDiscovery
    let missing = URL(filePath: "/omo-usage-plan-profile-tests/missing")

    init(planName: String?, now: Date) throws {
        let keychain = PlanProfileKeychain()
        try ProviderCredentialSnapshotStore(keychain: keychain).save(
            CredentialSnapshot(
                provider: .claude,
                accessToken: Self.accessToken,
                refreshToken: "plan-profile-refresh",
                accountReference: nil,
                planName: planName,
                expiresAt: now.addingTimeInterval(86_400),
                source: .keychain
            ),
            for: AccountProviderID(accountID: accountID, providerID: .claude)
        )
        discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: PlanProfileEmptyKeychain(),
            providerKeychain: keychain,
            homeDirectory: missing,
            commandPaths: []
        )
    }

    func provider(planCache: ClaudePlanCache) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            accountID: accountID,
            accountLabel: "floweredao",
            discovery: discovery,
            http: providerHTTPTestClient(session: PlanProfileURLProtocol.session()),
            desktopUsageURL: missing,
            desktopSessionDiscovery: .unavailable,
            refreshCooldown: ClaudeRefreshCooldown(),
            usageCooldown: ClaudeUsageCooldown(),
            planCache: planCache
        )
    }
}

private struct PlanProfileEmptyKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private final class PlanProfileKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(service: String, account: String) throws -> String? {
        lock.withLock { values["\(service)\u{0}\(account)"] }
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values["\(service)\u{0}\(account)"] = value }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: "\(service)\u{0}\(account)") }
    }
}

private final class PlanProfileURLProtocol: URLProtocol, @unchecked Sendable {
    enum Route { case usage, profile }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var profile: PlanProfileResponse = .status(404)
    private nonisolated(unsafe) static var counts: [Route: Int] = [:]
    private nonisolated(unsafe) static var profileRequest: URLRequest?

    static func install(profile response: PlanProfileResponse) {
        lock.withLock {
            profile = response
            counts = [:]
            profileRequest = nil
        }
    }

    static func uninstall() {
        install(profile: .status(404))
    }

    static func count(_ route: Route) -> Int {
        lock.withLock { counts[route, default: 0] }
    }

    static var lastProfileRequest: URLRequest? {
        lock.withLock { profileRequest }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanProfileURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch request.url?.absoluteString {
        case "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1":
            Self.lock.withLock { Self.counts[.usage, default: 0] += 1 }
            respond(200, #"{"five_hour":{"utilization":3},"seven_day":{"utilization":2}}"#)
        case "https://api.anthropic.com/api/oauth/profile":
            let response = Self.lock.withLock {
                Self.counts[.profile, default: 0] += 1
                Self.profileRequest = request
                return Self.profile
            }
            switch response {
            case .ok(let body): respond(200, body)
            case .status(let code): respond(code, "{}")
            }
        default:
            respond(404, "{}")
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
