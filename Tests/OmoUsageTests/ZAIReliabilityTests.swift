import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ZAIReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_786_032_000)

    @Test
    func classifiesQuotaWindowsByUnitAndNumberRegardlessOfOrder() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: """
            {
              "data": {
                "limits": [
                  {
                    "type": "CREDIT_LIMIT",
                    "unit": 6,
                    "number": 1,
                    "percentage": 40
                  },
                  {
                    "type": "CREDIT_LIMIT",
                    "unit": 3,
                    "number": 5,
                    "percentage": 20
                  },
                  {
                    "type": "TIME_LIMIT",
                    "currentValue": 2,
                    "usage": 10
                  }
                ]
              }
            }
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let meters = usage.groups.flatMap(\.meters)
        let weekly = try #require(meters.first { $0.id == "zai-week" })
        let session = try #require(meters.first { $0.id == "zai-session" })
        let search = try #require(meters.first { $0.id == "zai-search" })

        #expect(weekly.period == .week)
        #expect(weekly.percentRemaining == 60)
        #expect(session.period == .session)
        #expect(session.percentRemaining == 80)
        #expect(search.period == .extra)
        #expect(search.percentRemaining == 80)
    }

    @Test
    func rejectsUsageOnlyPayloadInsteadOfReportingZeroRemaining() async {
        do {
            _ = try await HephaestusZAIFixture.fetch(
                quota: """
                {"data":{"limits":[
                  {"type":"TIME_LIMIT","usage":10}
                ]}}
                """,
                subscription: #"{"data":[]}"#,
                now: now
            )
            Issue.record("Usage alone must not become both used and limit")
        } catch {
            #expect(
                error as? ProviderTransportError
                    == .invalidResponse(.zai)
            )
        }
    }

    @Test
    func parsesExplicitUsedAndLimitValues() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[
              {"type":"SEARCH_LIMIT","used":2,"limit":10}
            ]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )

        #expect(usage.groups.flatMap(\.meters).map(\.percentRemaining) == [80])
    }

    @Test
    func aggregatesRepeatedSearchAndTimeWindowsRegardlessOfOrder() async throws {
        let search = """
        {"type":"SEARCH_LIMIT","percentage":20,"nextResetTime":1786042800}
        """
        let time = """
        {"type":"TIME_LIMIT","currentValue":6,"usage":10,"nextResetTime":1786039200}
        """
        let first = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(search),\(time)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let second = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(time),\(search)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let firstMeters = first.groups.flatMap(\.meters)
        let secondMeters = second.groups.flatMap(\.meters)

        #expect(firstMeters == secondMeters)
        #expect(firstMeters.map(\.id) == ["zai-search"])
        #expect(firstMeters.first?.percentRemaining == 40)
    }

    @Test
    func aggregatesDuplicateWindowIdentitiesWithUniqueStableIDs() async throws {
        let firstWindow = """
        {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":20}
        """
        let secondWindow = """
        {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":70}
        """
        let first = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(firstWindow),\(secondWindow)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let second = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(secondWindow),\(firstWindow)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let meters = first.groups.flatMap(\.meters)

        #expect(meters == second.groups.flatMap(\.meters))
        #expect(meters.map(\.id) == ["zai-week"])
        #expect(Set(meters.map(\.id)).count == meters.count)
        #expect(meters.first?.percentRemaining == 30)
    }

    @Test
    func parsesSanitizedRealSchemaFixtureWithStableUnknownUnitOrder() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: HephaestusZAIQuotaFixture.sanitizedQuota,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let meters = usage.groups.flatMap(\.meters)

        #expect(meters.map(\.id) == [
            "zai-session",
            "zai-week",
            "zai-search",
            "zai-token-42-8"
        ])
        #expect(meters.map(\.percentRemaining) == [80, 80, 60, 75])
        #expect(Set(meters.map(\.id)).count == meters.count)
        #expect(!meters.contains { $0.percentRemaining == 0 })
    }

    @Test
    func parsesProductNameFromSubscriptionDataArray() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: """
            {
              "data": {
                "limits": [
                  {"type": "CREDIT_LIMIT", "percentage": 25}
                ]
              }
            }
            """,
            subscription: """
            {"data":[{"productName":"GLM Coding Max"}]}
            """,
            now: now
        )

        #expect(usage.planName == "GLM Coding Max")
    }

    @Test
    func explicitNoActiveCodingPlanIsUnavailable() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: """
            {"success":false,"code":500,"msg":"No active coding plan"}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )

        #expect(usage.availability == .unavailable)
        #expect(usage.groups.isEmpty)
    }

    @Test
    func emptyLimitsWithoutPlanIsUnavailable() async throws {
        let usage = try await HephaestusZAIFixture.fetch(
            quota: #"{"success":true,"data":{"limits":[]}}"#,
            subscription: #"{"data":[]}"#,
            now: now
        )

        #expect(usage.availability == .unavailable)
        #expect(usage.groups.isEmpty)
    }

    @Test
    func classifiesUnknownTokenWindowsRegardlessOfOrder() async throws {
        let known = """
        {
          "type": "CREDIT_LIMIT",
          "unit": 6,
          "number": 1,
          "percentage": 20
        }
        """
        let unknown = """
        {
          "type": "CREDIT_LIMIT",
          "unit": 99,
          "number": 2,
          "percentage": 40
        }
        """
        let first = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(unknown),\(known)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )
        let second = try await HephaestusZAIFixture.fetch(
            quota: """
            {"data":{"limits":[\(known),\(unknown)]}}
            """,
            subscription: #"{"data":[]}"#,
            now: now
        )

        #expect(first.groups.flatMap(\.meters) == second.groups.flatMap(\.meters))
        #expect(
            first.groups.flatMap(\.meters).map(\.id)
                == ["zai-week", "zai-token-99-2"]
        )
    }

    @Test
    func malformedQuotaPayloadRemainsInvalidResponse() async {
        do {
            _ = try await HephaestusZAIFixture.fetch(
                quota: #"{"success":true,"data":{"unexpected":[]}}"#,
                subscription: #"{"data":[]}"#,
                now: now
            )
            Issue.record("Expected malformed Z.AI quota payload to fail")
        } catch {
            #expect(
                error as? ProviderTransportError
                    == .invalidResponse(.zai)
            )
        }
    }
}

private enum HephaestusZAIQuotaFixture {
    static let sanitizedQuota = """
    {
      "data": {
        "limits": [
          {
            "type": "CREDIT_LIMIT",
            "unit": 42,
            "number": 8,
            "percentage": 25,
            "nextResetTime": 1786122000
          },
          {
            "type": "TIME_LIMIT",
            "currentValue": 4,
            "usage": 10,
            "nextResetTime": 1786039200
          },
          {
            "type": "CREDIT_LIMIT",
            "unit": 6,
            "number": 1,
            "used": 2,
            "limit": 10,
            "nextResetTime": 1786644000
          },
          {
            "type": "SEARCH_LIMIT",
            "usage": 3,
            "limit": 12,
            "nextResetTime": 1786042800
          },
          {
            "type": "CREDIT_LIMIT",
            "unit": 3,
            "number": 5,
            "currentValue": 1,
            "usage": 5,
            "nextResetTime": 1786035600
          }
        ]
      }
    }
    """
}

private enum HephaestusZAIFixture {
    static func fetch(
        quota: String,
        subscription: String,
        now: Date
    ) async throws -> ProviderUsage {
        let token = "hephaestus-zai-\(UUID().uuidString)"
        HephaestusZAIResponseStore.shared.register(
            token: token,
            quota: quota,
            subscription: subscription
        )
        defer { HephaestusZAIResponseStore.shared.unregister(token: token) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HephaestusZAIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let missing = URL(
            filePath: "/hephaestus-zai-\(UUID().uuidString)"
        )
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: missing.appending(path: "claude.json"),
                codex: missing.appending(path: "codex.json")
            ),
            environment: ["ZAI_API_KEY": token],
            keychain: HephaestusZAIMissingKeychain(),
            homeDirectory: missing,
            commandPaths: []
        )

        return try await ZAIUsageProvider(
            discovery: discovery,
            http: ProviderHTTP(session: session)
        ).fetch(now: now)
    }
}

private struct HephaestusZAIMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class HephaestusZAIResponseStore: @unchecked Sendable {
    struct Response {
        let quota: String
        let subscription: String
    }

    static let shared = HephaestusZAIResponseStore()

    private let lock = NSLock()
    private var responses: [String: Response] = [:]

    func register(token: String, quota: String, subscription: String) {
        lock.withLock {
            responses[token] = Response(
                quota: quota,
                subscription: subscription
            )
        }
    }

    func unregister(token: String) {
        _ = lock.withLock {
            responses.removeValue(forKey: token)
        }
    }

    func response(for request: URLRequest) -> Response? {
        guard let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        ) else {
            return nil
        }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        let token = String(authorization.dropFirst(prefix.count))
        return lock.withLock { responses[token] }
    }
}

private final class HephaestusZAIURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.z.ai"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let fixture = HephaestusZAIResponseStore.shared.response(
                for: request
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        #expect(request.httpMethod == "GET")
        #expect(
            [
                "/api/monitor/usage/quota/limit",
                "/api/biz/subscription/list"
            ].contains(url.path)
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("Bearer ") == true
        )
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/json"
        )
        #expect(requestBodyData(request) == nil)
        let body = url.path.hasSuffix("/subscription/list")
            ? fixture.subscription
            : fixture.quota
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
}
