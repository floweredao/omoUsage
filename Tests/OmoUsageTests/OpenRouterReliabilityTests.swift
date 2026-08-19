import Foundation
import Testing
@testable import OmoUsage

@Suite
struct OpenRouterReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_786_032_000)

    @Test
    func mapsDocumentedLimitRemainingAndFreeTier() async throws {
        let usage = try await HephaestusOpenRouterFixture.fetch(
            scenario: .init(
                creditsStatus: 200,
                creditsBody: #"{"data":{"total_credits":100,"total_usage":25}}"#,
                keyStatus: 200,
                keyBody: #"{"data":{"limit":200,"usage":150,"limit_remaining":80,"is_free_tier":true}}"#
            ),
            now: now
        )
        let meters = Dictionary(
            uniqueKeysWithValues: usage.groups
                .flatMap(\.meters)
                .map { ($0.id, $0.percentRemaining) }
        )

        #expect(usage.provider == .openrouter)
        #expect(usage.planName == "Free")
        #expect(usage.availability == .available)
        #expect(usage.updatedAt == now)
        #expect(meters["openrouter-key"] == 40)
    }

    @Test
    func mapsNonFreeTierToPaidPlan() async throws {
        let usage = try await HephaestusOpenRouterFixture.fetch(
            scenario: .init(
                creditsStatus: 200,
                creditsBody: #"{"data":{"total_credits":50,"total_usage":10}}"#,
                keyStatus: 200,
                keyBody: #"{"data":{"limit":100,"usage":20,"limit_remaining":80,"is_free_tier":false}}"#
            ),
            now: now
        )

        #expect(usage.planName == "Paid")
    }

    @Test
    func keyMetadataRemainsAvailableWhenCreditsRequestFails() async throws {
        let usage = try await HephaestusOpenRouterFixture.fetch(
            scenario: .init(
                creditsStatus: 503,
                creditsBody: #"{"error":"temporarily unavailable"}"#,
                keyStatus: 200,
                keyBody: #"{"data":{"limit":400,"usage":300,"limit_remaining":160,"is_free_tier":false}}"#
            ),
            now: now
        )
        let meters = usage.groups.flatMap(\.meters)

        #expect(usage.provider == .openrouter)
        #expect(usage.planName == "Paid")
        #expect(usage.availability == .available)
        #expect(usage.updatedAt == now)
        #expect(meters.map(\.id) == ["openrouter-key"])
        #expect(meters.map(\.period) == [.extra])
        #expect(meters.map(\.percentRemaining) == [40])
    }

    @Test
    func allAuthenticationFailuresRemainAuthenticationFailures() async {
        do {
            _ = try await HephaestusOpenRouterFixture.fetch(
                scenario: .init(
                    creditsStatus: 401,
                    creditsBody: #"{"error":"unauthorized"}"#,
                    keyStatus: 403,
                    keyBody: #"{"error":"forbidden"}"#
                ),
                now: now
            )
            Issue.record("Expected authentication failure")
        } catch {
            #expect(
                error as? ProviderTransportError
                    == .authenticationRequired(.openrouter)
            )
        }
    }
}

private enum HephaestusOpenRouterFixture {
    static func fetch(
        scenario: HephaestusOpenRouterScenario,
        now: Date
    ) async throws -> ProviderUsage {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusOpenRouterReliability-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let credential = directory.appending(
            path: ".config/openusage/openrouter.json"
        )
        try FileManager.default.createDirectory(
            at: credential.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let token = "hephaestus-openrouter-\(UUID().uuidString)"
        try JSONSerialization.data(
            withJSONObject: ["apiKey": token]
        ).write(to: credential)
        defer { try? FileManager.default.removeItem(at: directory) }

        HephaestusOpenRouterURLProtocol.register(
            token: token,
            scenario: scenario
        )
        defer { HephaestusOpenRouterURLProtocol.unregister(token: token) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HephaestusOpenRouterURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let provider = OpenRouterUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: directory.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: HephaestusOpenRouterMissingKeychain(),
                homeDirectory: directory,
                commandPaths: []
            ),
            http: ProviderHTTP(session: session)
        )

        return try await provider.fetch(now: now)
    }
}

private struct HephaestusOpenRouterMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private struct HephaestusOpenRouterScenario: Sendable {
    let creditsStatus: Int
    let creditsBody: String
    let keyStatus: Int
    let keyBody: String
}

private final class HephaestusOpenRouterScenarioStore: @unchecked Sendable {
    static let shared = HephaestusOpenRouterScenarioStore()

    private let lock = NSLock()
    private var scenarios: [String: HephaestusOpenRouterScenario] = [:]

    func register(token: String, scenario: HephaestusOpenRouterScenario) {
        lock.withLock {
            scenarios[token] = scenario
        }
    }

    func unregister(token: String) {
        _ = lock.withLock {
            scenarios.removeValue(forKey: token)
        }
    }

    func scenario(for request: URLRequest) -> HephaestusOpenRouterScenario? {
        let prefix = "Bearer "
        guard let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        ), authorization.hasPrefix(prefix) else {
            return nil
        }
        let token = String(authorization.dropFirst(prefix.count))
        return lock.withLock { scenarios[token] }
    }
}

private final class HephaestusOpenRouterURLProtocol: URLProtocol,
    @unchecked Sendable
{
    static func register(
        token: String,
        scenario: HephaestusOpenRouterScenario
    ) {
        HephaestusOpenRouterScenarioStore.shared.register(
            token: token,
            scenario: scenario
        )
    }

    static func unregister(token: String) {
        HephaestusOpenRouterScenarioStore.shared.unregister(token: token)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openrouter.ai"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let scenario = HephaestusOpenRouterScenarioStore.shared
                .scenario(for: request)
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let result: (status: Int, body: String)
        switch url.path {
        case "/api/v1/credits":
            result = (scenario.creditsStatus, scenario.creditsBody)
        case "/api/v1/key":
            result = (scenario.keyStatus, scenario.keyBody)
        default:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: result.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
